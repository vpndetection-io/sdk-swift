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

    /// The licensed dataset downloads, for keys that carry the `db.download` scope.
    public let database: DatabaseAPI

    private let api: Client
    private let cache: ResultCache?
    private let concurrency: Int
    private let retries: Int

    public init(options: Options = Options()) {
        precondition(options.concurrency > 0, "concurrency must be positive")
        precondition(options.retries >= 0, "retries cannot be negative")

        var middlewares: [any ClientMiddleware] = []
        if let apiKey = options.apiKey {
            middlewares.append(AuthMiddleware(apiKey: apiKey))
        }
        middlewares.append(ErrorMiddleware())

        // Resolved once, because the download path calls object storage straight
        // through the transport rather than through the generated client and has
        // to reach the same implementation a caller substituted.
        let transport = options.transport ?? DefaultTransport.shared
        self.api = Client(
            serverURL: options.baseURL,
            configuration: Configuration(dateTranscoder: LenientDateTranscoder()),
            transport: transport,
            middlewares: middlewares,
        )
        self.cache = options.cache.map(ResultCache.init)
        self.concurrency = options.concurrency
        self.retries = options.retries
        self.database = DatabaseAPI(api: api, transport: transport, retries: options.retries)
    }

    /// A client that presents `apiKey` and takes every other default.
    public init(apiKey: String) {
        self.init(options: Options(apiKey: apiKey))
    }

    /// Whether an address is private, loopback, link-local, documentation,
    /// multicast or otherwise not routable, including the IPv6 equivalents and
    /// the 6to4 and Teredo ranges.
    ///
    /// These are the addresses ``lookup(_:retries:)`` answers locally. Exposed
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
    /// - Parameter retries: Overrides the client's retry count for this call.
    public func lookup(_ ip: String, retries: Int? = nil) async throws -> LookupResult {
        if isBogon(ip) {
            return LookupResult.bogon(ip)
        }
        if let hit = await cache?.get(ip) {
            return hit
        }
        let result = try await withRetry(retries ?? self.retries) {
            let output = try await api.lookupIp(path: .init(ip: ip))
            guard case .ok(let ok) = output else {
                throw VPNDetectionError(
                    kind: .serverError, message: "unexpected response: \(output)",
                )
            }
            return LookupResult(try ok.body.json)
        }
        await cache?.set(ip, result)
        return result
    }

    /// Classify many addresses concurrently.
    ///
    /// Duplicates in the input collapse to a single request, bogons never reach
    /// the network, and the answers come back keyed by address in input order.
    /// An address that fails carries its error as its value.
    ///
    /// - Throws: Only if the surrounding task is cancelled. A per-address
    ///   failure is a value in the result, not a thrown error.
    public func lookupBatch(
        _ ips: some Sequence<String>, options: BatchOptions = BatchOptions(),
    ) async throws -> BatchResults {
        let limit = options.concurrency ?? concurrency
        precondition(limit > 0, "concurrency must be positive")

        var keys: [String] = []
        var seen: Set<String> = []
        for ip in ips where seen.insert(ip).inserted {
            keys.append(ip)
        }

        var outcomes: [String: BatchResults.Outcome] = [:]
        outcomes.reserveCapacity(keys.count)
        // Primed with `limit` children and topped back up as each one lands, so
        // peak in-flight is the limit rather than the size of the input, and a
        // per-call limit has no shared limiter that could cap it.
        try await withThrowingTaskGroup(of: (String, BatchResults.Outcome).self) { group in
            var next = 0
            while next < min(limit, keys.count) {
                guard group.addTaskUnlessCancelled(operation: lookupTask(keys[next], options)) else {
                    break
                }
                next += 1
            }
            while let (ip, outcome) = try await group.next() {
                outcomes[ip] = outcome
                guard next < keys.count else {
                    continue
                }
                group.addTask(operation: lookupTask(keys[next], options))
                next += 1
            }
        }
        // Covers the one case no child can report: cancellation before the group
        // was primed, where nothing ran and the result would otherwise be keys
        // with no outcome behind them.
        try Task.checkCancellation()
        return BatchResults(keys: keys, outcomes: outcomes)
    }

    private func lookupTask(
        _ ip: String, _ options: BatchOptions,
    ) -> @Sendable () async throws -> (String, BatchResults.Outcome) {
        { [self] in
            do {
                return (ip, .success(try await lookup(ip, retries: options.retries)))
            } catch is CancellationError {
                // The batch is being torn down; that is not this address failing.
                throw CancellationError()
            } catch {
                return (ip, .failure(VPNDetectionError.wrapping(error)))
            }
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
        public var baseURL: URL
        /// Set to `nil` to disable caching.
        public var cache: CacheOptions?
        /// Concurrent in-flight requests during a batch. Default 8.
        public var concurrency: Int
        /// Retry attempts for a transient failure. Default 2.
        public var retries: Int
        /// Override the HTTP implementation. Anything you supply owns its own
        /// redirect policy, and the download endpoint's `302` must not be
        /// followed; see ``DatabaseAPI/downloadURL(id:format:)``.
        public var transport: (any ClientTransport)?

        public init(
            apiKey: String? = nil,
            baseURL: URL = VPNDetectionClient.defaultBaseURL,
            cache: CacheOptions? = CacheOptions(),
            concurrency: Int = 8,
            retries: Int = 2,
            transport: (any ClientTransport)? = nil,
        ) {
            self.apiKey = apiKey
            self.baseURL = baseURL
            self.cache = cache
            self.concurrency = concurrency
            self.retries = retries
            self.transport = transport
        }
    }

    /// Per-call overrides for one batch. Anything left `nil` falls back to the
    /// client's setting.
    ///
    /// There is deliberately no equivalent on ``lookup(_:retries:)``: a
    /// concurrency for a single address is meaningless, and a type that accepted
    /// one and ignored it would pass any test that only checked the option was
    /// accepted.
    public struct BatchOptions: Sendable, Hashable {
        /// Concurrent in-flight requests for THIS batch only.
        public var concurrency: Int?
        /// Retry attempts for a transient failure, for THIS batch only.
        public var retries: Int?

        public init(concurrency: Int? = nil, retries: Int? = nil) {
            self.concurrency = concurrency
            self.retries = retries
        }
    }
}
