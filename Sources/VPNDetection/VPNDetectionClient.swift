import Foundation
import OpenAPIRuntime

/// A client for the VPNDetection API.
///
/// A `struct` rather than an `actor`: the only mutable state is the answer cache,
/// which is isolated inside its own actor, so the client itself is immutable and
/// `Sendable` and its methods run on whatever executor called them. Making the
/// whole client an actor would serialize every entry and exit for no benefit.
///
/// The cache is per instance, so an answer is never shared between two clients
/// holding different API keys and therefore entitled to different fields.
public struct VPNDetectionClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://api.vpndetection.io")!

    /// The most addresses `POST /batch` takes in one call; a larger batch is
    /// sent in chunks of this size.
    static let batchMax = 1000

    /// The licensed dataset downloads, for keys that carry the `db.download` scope.
    public let database: DatabaseAPI

    /// Sign a person in with OAuth's device flow and receive one of their API
    /// keys. Its requests never carry this client's key.
    public let oauth: OauthAPI

    private let api: Client
    private let cache: ResultCache?
    private let concurrency: Int
    private let retries: Int
    private let timeout: Duration

    public init(options: Options = Options()) {
        precondition(options.concurrency > 0, "concurrency must be positive")
        precondition(options.retries >= 0, "retries cannot be negative")
        precondition(options.timeout > .zero, "timeout must be positive")
        precondition(options.timeout <= maxTimeout, "timeout is longer than the runtime can count")

        var middlewares: [any ClientMiddleware] = []
        // An empty key is treated as no key. It is what an unset environment
        // variable or CI secret interpolates to, and `Bearer ` with nothing
        // behind it is never what anyone meant - the API would refuse it as
        // unauthorized rather than serve the anonymous tier that was intended.
        if let apiKey = options.apiKey, !apiKey.isEmpty {
            middlewares.append(AuthMiddleware(apiKey: apiKey))
        }
        middlewares.append(ErrorMiddleware())

        // Resolved once, because the download path calls object storage straight
        // through the transport rather than through the generated client and has
        // to reach the same implementation a caller substituted.
        let transport = options.transport ?? DefaultTransport.shared
        let baseURL = withoutTrailingSlashes(options.baseURL)
        self.api = Client(
            serverURL: baseURL,
            configuration: Configuration(dateTranscoder: LenientDateTranscoder()),
            transport: transport,
            middlewares: middlewares,
        )
        self.cache = options.cache.map(ResultCache.init)
        self.concurrency = options.concurrency
        self.retries = options.retries
        self.timeout = options.timeout
        self.database = DatabaseAPI(
            api: api, transport: transport, retries: options.retries, timeout: options.timeout,
        )
        self.oauth = OauthAPI(
            transport: transport, baseURL: baseURL, retries: options.retries,
            timeout: options.timeout,
        )
    }

    /// A client that presents `apiKey` and takes every other default.
    public init(apiKey: String) {
        self.init(options: Options(apiKey: apiKey))
    }

    /// Whether an address is private, loopback, link-local, documentation,
    /// multicast or otherwise not routable, including the IPv6 equivalents and
    /// the 6to4 and Teredo ranges.
    ///
    /// These are the addresses ``lookup(_:retries:timeout:)`` answers locally. Exposed
    /// here so the check is reachable from the client you already hold; the same
    /// function is also available on its own as ``VPNDetection/isBogon(_:)``.
    public func isBogon(_ ip: String) -> Bool {
        VPNDetection.isBogon(ip)
    }

    /// Classify one address.
    ///
    /// A bogon is answered locally and never reaches the network. Everything
    /// else is served, then cached for this instance.
    ///
    /// - Parameters:
    ///   - retries: Overrides the client's retry count for this call.
    ///   - timeout: Overrides the client's ``Options/timeout`` for this call, in
    ///     either direction. It bounds each attempt, from sending the request to
    ///     decoding the answer.
    public func lookup(
        _ ip: String, retries: Int? = nil, timeout: Duration? = nil,
    ) async throws -> LookupResult {
        if isBogon(ip) {
            return LookupResult.bogon(ip)
        }
        if let hit = await cache?.get(ip) {
            return hit
        }
        let result = try await withRetry(retries ?? self.retries) {
            try await withDeadline(timeout ?? self.timeout) {
                let output = try await api.lookupIp(path: .init(ip: ip))
                guard case .ok(let ok) = output else {
                    throw VPNDetectionError(
                        kind: .serverError, message: "unexpected response: \(output)",
                    )
                }
                return LookupResult(try ok.body.json)
            }
        }
        await cache?.set(ip, result)
        return result
    }

    /// Classify the address this client is calling from.
    ///
    /// The same answer ``lookup(_:retries:timeout:)`` would give for that address, at
    /// the same cost against your allowance. The address is the one our edge
    /// observed, so a call made through a proxy or a VPN reports the exit it
    /// left through - usually the point of asking.
    ///
    /// Deliberately NOT cached. The cache is keyed by address, and which
    /// address this is IS the question: a machine that moves between networks
    /// would otherwise be told where it used to be.
    ///
    /// - Parameters:
    ///   - retries: Overrides the client's retry count for this call.
    ///   - timeout: Bounds each attempt, as on ``lookup(_:retries:timeout:)``.
    public func myIP(retries: Int? = nil, timeout: Duration? = nil) async throws -> LookupResult {
        try await withRetry(retries ?? self.retries) {
            try await withDeadline(timeout ?? self.timeout) {
                let output = try await api.lookupMyIp()
                guard case .ok(let ok) = output else {
                    throw VPNDetectionError(
                        kind: .serverError, message: "unexpected response: \(output)",
                    )
                }
                return LookupResult(try ok.body.json)
            }
        }
    }

    /// What this client's key is entitled to, and how much of it has been used.
    ///
    /// Named for what it answers rather than `me`, which sits one letter from
    /// ``myIP(retries:timeout:)`` and means something quite different: one is which
    /// address you are calling FROM, the other is what the key you are calling
    /// WITH may spend.
    ///
    /// Unlike a lookup there is no useful unauthenticated answer, so a client
    /// built without an API key gets an unauthorized error rather than a
    /// partial one.
    ///
    /// Usage counts against the ALLOWANCE WINDOW - the anniversary of the
    /// subscription, not the calendar month and not the billing period - and it
    /// is the same number a lookup is gated on. It can lag by a few seconds,
    /// because requests are counted in memory and flushed in aggregate.
    ///
    /// Deliberately NOT cached: the whole point is what has been spent, and a
    /// cached answer is a wrong one within seconds of the next request.
    ///
    /// - Parameters:
    ///   - retries: Overrides the client's retry count for this call.
    ///   - timeout: Bounds each attempt, as on ``lookup(_:retries:timeout:)``.
    public func myEntitlement(
        retries: Int? = nil, timeout: Duration? = nil,
    ) async throws -> Entitlement {
        try await withRetry(retries ?? self.retries) {
            try await withDeadline(timeout ?? self.timeout) {
                let output = try await api.myEntitlement()
                guard case .ok(let ok) = output else {
                    throw VPNDetectionError(
                        kind: .serverError, message: "unexpected response: \(output)",
                    )
                }
                return Entitlement(try ok.body.json)
            }
        }
    }

    /// Classifies many addresses in as few requests as possible.
    ///
    /// Bogons are answered locally and cached answers are reused; everything
    /// else goes to `POST /batch` in chunks of up to 1000 addresses, with at
    /// most `concurrency` chunks in flight. Keyed by address rather than
    /// positional, so duplicates in the input collapse to a single entry and the
    /// caller never has to line two lists up. An address that fails carries its
    /// error as its value, so one bad entry cannot lose the rest of the answers:
    /// the API reports a per-entry failure with the status the single lookup
    /// would have answered, and a chunk that fails as a whole marks every
    /// address in it.
    ///
    /// Throws only when cancelled, or when ``BatchOptions/concurrency`` is below
    /// 1 or ``BatchOptions/timeout`` is a bound no attempt could meet, each
    /// refused as ``VPNDetectionErrorKind/badRequest`` before any request.
    public func lookupBatch(
        _ ips: some Sequence<String>, options: BatchOptions = BatchOptions(),
    ) async throws -> BatchResults {
        let limit = options.concurrency ?? concurrency
        // A group primed with no children would wait for none, forever.
        guard limit > 0 else {
            throw VPNDetectionError(
                kind: .badRequest, message: "concurrency must be at least 1, got \(limit)",
            )
        }
        // Refused up front, like the concurrency above: a batch answers bogons and
        // cache hits without an attempt, so a bound checked only per chunk would be
        // accepted or refused depending on which addresses it happened to hold.
        if let timeout = options.timeout {
            try checkTimeout(timeout)
        }

        var keys: [String] = []
        var seen: Set<String> = []
        for ip in ips where seen.insert(ip).inserted {
            keys.append(ip)
        }

        var outcomes: [String: BatchResults.Outcome] = [:]
        outcomes.reserveCapacity(keys.count)
        var pending: [String] = []
        for ip in keys {
            if isBogon(ip) {
                outcomes[ip] = .success(LookupResult.bogon(ip))
                continue
            }
            if let hit = await cache?.get(ip) {
                outcomes[ip] = .success(hit)
                continue
            }
            pending.append(ip)
        }
        let chunks = stride(from: 0, to: pending.count, by: Self.batchMax).map {
            Array(pending[$0..<min($0 + Self.batchMax, pending.count)])
        }

        // Primed with `limit` children and topped back up as each one lands, so
        // peak in-flight is the limit rather than the number of chunks, and a
        // per-call limit has no shared limiter that could cap it.
        try await withThrowingTaskGroup(of: [(String, BatchResults.Outcome)].self) { group in
            var next = 0
            while next < min(limit, chunks.count) {
                guard group.addTaskUnlessCancelled(operation: chunkTask(chunks[next], options)) else {
                    break
                }
                next += 1
            }
            while let answers = try await group.next() {
                for (ip, outcome) in answers {
                    outcomes[ip] = outcome
                }
                guard next < chunks.count else {
                    continue
                }
                group.addTask(operation: chunkTask(chunks[next], options))
                next += 1
            }
        }
        // Covers the one case no child can report: cancellation before the group
        // was primed, where nothing ran and the result would otherwise be keys
        // with no outcome behind them.
        try Task.checkCancellation()
        return BatchResults(keys: keys, outcomes: outcomes)
    }

    /// One `POST /batch`, mapped back onto the addresses it was asked about. A
    /// chunk-level failure - the call refused, the transport failing, the
    /// retries exhausted - becomes every address's error, exactly as it would
    /// have been had each been looked up alone.
    private func chunkTask(
        _ chunk: [String], _ options: BatchOptions,
    ) -> @Sendable () async throws -> [(String, BatchResults.Outcome)] {
        { [self] in
            let body: Components.Schemas.BatchLookupResponse
            do {
                body = try await withRetry(options.retries ?? retries) {
                    try await withDeadline(options.timeout ?? timeout) {
                        let output = try await api.lookupBatch(.init(body: .json(.init(ips: chunk))))
                        guard case .ok(let ok) = output else {
                            throw VPNDetectionError(
                                kind: .serverError, message: "unexpected response: \(output)",
                            )
                        }
                        return try ok.body.json
                    }
                }
            } catch is CancellationError {
                // The batch is being torn down; that is not this chunk failing.
                throw CancellationError()
            } catch {
                let failure = VPNDetectionError.wrapping(error)
                return chunk.map { ($0, .failure(failure)) }
            }
            var answers: [(String, BatchResults.Outcome)] = []
            answers.reserveCapacity(chunk.count)
            for ip in chunk {
                if let served = body.results.additionalProperties[ip] {
                    let result = LookupResult(served)
                    await cache?.set(ip, result)
                    answers.append((ip, .success(result)))
                    continue
                }
                if let failed = body.errors.additionalProperties[ip] {
                    let error = VPNDetectionError.fromEntry(status: failed.status, message: failed.error)
                    answers.append((ip, .failure(error)))
                    continue
                }
                answers.append((ip, .failure(VPNDetectionError(
                    kind: .serverError, message: "the batch answer did not include \(ip)", status: 200,
                ))))
            }
            return answers
        }
    }
}

extension VPNDetectionClient {
    /// How a client behaves. Everything has a default; an empty `Options` is the
    /// free tier against production.
    public struct Options: Sendable {
        /// Your API key. Omit it entirely to use the free tier, which answers
        /// `ip` and `is_vpn` and allows 1000 requests per day per source address.
        public var apiKey: String?
        /// Where the API is served. Default ``VPNDetectionClient/defaultBaseURL``.
        ///
        /// A trailing slash is dropped. Every path this client appends begins with
        /// one and the transport appends it to whatever path the base URL already
        /// carries, so `https://api.vpndetection.io/` would ask for `//api/v1/...`.
        /// That is a different path to the server: production answers it with a
        /// `301` the default transport refuses to follow, so every call would fail.
        public var baseURL: URL
        /// Set to `nil` to disable caching.
        public var cache: CacheOptions?
        /// Concurrent batch requests - chunks of up to 1000 addresses - during a batch. Default 8.
        public var concurrency: Int
        /// Retry attempts for a transient failure. Default 2.
        public var retries: Int
        /// How long one attempt may take, from sending the request to decoding
        /// the answer. Default 30 seconds. Per ATTEMPT, so a retried call may
        /// take longer in total, and a call's own `timeout` replaces it in either
        /// direction. A dataset transfer is bounded only until its response head
        /// arrives, so a download that takes minutes is not cut off.
        ///
        /// Must be positive, and short enough for the concurrency runtime to count
        /// to. Zero, a negative duration and one near the top of `Int64` seconds
        /// are each a bound no attempt could meet; a call given one refuses it as
        /// ``VPNDetectionErrorKind/badRequest`` rather than failing on the wire.
        public var timeout: Duration
        /// Override the HTTP implementation. Anything you supply owns its own
        /// redirect policy, and the download endpoint's `302` must not be
        /// followed; see ``DatabaseAPI/downloadURL(id:format:timeout:)``.
        public var transport: (any ClientTransport)?

        public init(
            apiKey: String? = nil,
            baseURL: URL = VPNDetectionClient.defaultBaseURL,
            cache: CacheOptions? = CacheOptions(),
            concurrency: Int = 8,
            retries: Int = 2,
            timeout: Duration = .seconds(30),
            transport: (any ClientTransport)? = nil,
        ) {
            self.apiKey = apiKey
            self.baseURL = baseURL
            self.cache = cache
            self.concurrency = concurrency
            self.retries = retries
            self.timeout = timeout
            self.transport = transport
        }
    }

    /// Per-call overrides for one batch. Anything left `nil` falls back to the
    /// client's setting.
    ///
    /// There is deliberately no equivalent on ``lookup(_:retries:timeout:)``: a
    /// concurrency for a single address is meaningless, and a type that accepted
    /// one and ignored it would pass any test that only checked the option was
    /// accepted.
    public struct BatchOptions: Sendable, Hashable {
        /// Concurrent batch requests - chunks of up to 1000 addresses - for THIS batch only.
        public var concurrency: Int?
        /// Retry attempts for a transient failure, for THIS batch only.
        public var retries: Int?
        /// How long one attempt at one chunk may take, for THIS batch only, in
        /// place of the client's ``VPNDetectionClient/Options/timeout``. A chunk
        /// that runs out of it marks every address in it with a retryable network
        /// error. One no attempt could meet is refused as
        /// ``VPNDetectionErrorKind/badRequest`` before any request, as a
        /// ``concurrency`` below 1 is.
        public var timeout: Duration?

        public init(concurrency: Int? = nil, retries: Int? = nil, timeout: Duration? = nil) {
            self.concurrency = concurrency
            self.retries = retries
            self.timeout = timeout
        }
    }
}

// Every path the generated client appends begins with a slash, and the transport
// appends it to whatever path the base URL already carries, so a base URL ending
// in one asks for `//api/v1/...`. That is a different path to the server, which
// answers it with a `301` the default transport refuses to follow, so every call
// fails. Every trailing slash goes rather than one: dropping a single slash
// still doubles `.../`.
private func withoutTrailingSlashes(_ url: URL) -> URL {
    var text = url.absoluteString
    while text.hasSuffix("/") {
        text.removeLast()
    }
    return URL(string: text) ?? url
}
