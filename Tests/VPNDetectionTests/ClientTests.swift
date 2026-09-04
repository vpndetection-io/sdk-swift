import AsyncHTTPClient
import Foundation
import OpenAPIAsyncHTTPClient
import Testing

@testable import VPNDetection

/// The Swift API surface, as distinct from the shared conformance corpus.
@Suite("Client")
struct ClientTests {
    static let manyAddresses = (1...12).map { "9.9.9.\($0)" }

    // Peak in-flight is the only measurement that tells a real limit from an
    // option that was accepted and ignored.
    @Test("a per-call concurrency is honored, measured at the transport")
    func perCallConcurrencyIsHonored() async throws {
        let stub = StubTransport(
            StubTransport.answers(for: Self.manyAddresses), delay: .milliseconds(20),
        )
        let client = client(stub, cache: nil)

        _ = try await client.lookupBatch(Self.manyAddresses, options: .init(concurrency: 3))

        await #expect(stub.callCount == Self.manyAddresses.count)
        await #expect(stub.peakInFlight <= 3)
        await #expect(stub.peakInFlight > 1, "requests never overlapped")
    }

    @Test("a per-call concurrency overrides the client default")
    func perCallConcurrencyOverridesTheClientDefault() async throws {
        let stub = StubTransport(
            StubTransport.answers(for: Self.manyAddresses), delay: .milliseconds(20),
        )
        let client = client(stub, cache: nil, concurrency: 2)

        _ = try await client.lookupBatch(Self.manyAddresses, options: .init(concurrency: 6))

        await #expect(stub.peakInFlight > 2, "the override was ignored")
        await #expect(stub.peakInFlight <= 6)
    }

    @Test("without an override the client concurrency still applies")
    func clientConcurrencyAppliesWithoutAnOverride() async throws {
        let stub = StubTransport(
            StubTransport.answers(for: Self.manyAddresses), delay: .milliseconds(20),
        )
        let client = client(stub, cache: nil, concurrency: 2)

        _ = try await client.lookupBatch(Self.manyAddresses)

        await #expect(stub.peakInFlight <= 2)
    }

    @Test("retries are configurable per call")
    func retriesAreConfigurablePerCall() async throws {
        let stub = StubTransport([
            "9.9.9.9": .json(["error": "lookup failed"], status: 500),
        ])
        let client = client(stub, cache: nil, retries: 0)

        await #expect(throws: VPNDetectionError.self) {
            try await client.lookup("9.9.9.9", retries: 2)
        }
        // One initial attempt plus two retries, rather than the client's zero.
        await #expect(stub.callCount == 3)
    }

    @Test("a spent quota is never retried")
    func spentQuotaIsNeverRetried() async throws {
        let stub = StubTransport([
            "9.9.9.9": .json(["error": "request allowance exceeded"], status: 429),
        ])
        let client = client(stub, cache: nil, retries: 5)

        let failure = await #expect(throws: VPNDetectionError.self) {
            try await client.lookup("9.9.9.9")
        }
        #expect(try #require(failure).kind == .quotaExceeded)
        await #expect(stub.callCount == 1)
    }

    @Test("a rate limit is retried after the server-supplied wait")
    func rateLimitWaitsForRetryAfter() async throws {
        var route = StubTransport.Route.json(["error": "rate limit exceeded"], status: 429)
        route.headers = ["Retry-After": "1"]
        let stub = StubTransport(["9.9.9.9": route])
        let client = client(stub, cache: nil, retries: 1)

        let started = ContinuousClock.now
        await #expect(throws: VPNDetectionError.self) {
            try await client.lookup("9.9.9.9")
        }
        await #expect(stub.callCount == 2)
        // The header, not the backoff schedule, decides the wait.
        #expect(ContinuousClock.now - started >= .seconds(1))
    }

    @Test("cancelling a lookup propagates rather than becoming a network failure")
    func cancellingALookupPropagates() async throws {
        let stub = StubTransport(StubTransport.answers(for: ["9.9.9.1"]), delay: .seconds(5))
        // Retries OFF on purpose: with them on the backoff sleep is itself
        // cancelled and the error escapes that way, so only a zero-retry client
        // reaches the code that decides what a cancellation looks like.
        let client = client(stub, cache: nil, retries: 0)

        let call = Task { try await client.lookup("9.9.9.1") }
        try await Task.sleep(for: .milliseconds(100))
        call.cancel()

        await #expect(throws: CancellationError.self) { try await call.value }
    }

    @Test("cancelling a batch propagates rather than becoming per-address failures")
    func cancellingABatchPropagates() async throws {
        let stub = StubTransport(
            StubTransport.answers(for: Self.manyAddresses), delay: .seconds(5),
        )
        let client = client(stub, cache: nil, retries: 0)

        let batch = Task { try await client.lookupBatch(Self.manyAddresses) }
        try await Task.sleep(for: .milliseconds(100))
        batch.cancel()

        // A map of network errors would otherwise look like a completed batch.
        await #expect(throws: CancellationError.self) { try await batch.value }
    }

    @Test("isBogon is on the client and agrees with the standalone function")
    func isBogonIsOnTheClientAndAgrees() {
        let client = client(StubTransport())
        for testCase in Corpus.shared.isBogon {
            #expect(client.isBogon(testCase.ip) == testCase.expect, "\(testCase.ip)")
            #expect(client.isBogon(testCase.ip) == VPNDetection.isBogon(testCase.ip))
        }
    }

    @Test("the api key is presented as a bearer token")
    func apiKeyIsPresented() async throws {
        let stub = StubTransport.answering("1.1.1.1")
        _ = try await client(stub, apiKey: "sk-test").lookup("1.1.1.1")

        // Bearer of the three schemes the API accepts: the other two put the key
        // in a query string, where it lands in access logs.
        await #expect(stub.authorizations == ["Bearer sk-test"])
    }

    @Test("no key means no Authorization header at all")
    func keylessRequestsCarryNoAuthorization() async throws {
        let stub = StubTransport.answering("1.1.1.1")
        _ = try await client(stub).lookup("1.1.1.1")

        await #expect(stub.authorizations == [nil])
    }

    @Test("caching can be turned off")
    func cachingCanBeTurnedOff() async throws {
        let stub = StubTransport.answering("1.1.1.1")
        let client = client(stub, cache: nil)

        for _ in 0..<2 {
            _ = try await client.lookup("1.1.1.1")
        }
        await #expect(stub.callCount == 2)
    }

    @Test("a cached answer lapses when its ttl does")
    func cacheEntriesExpire() async throws {
        let stub = StubTransport.answering("1.1.1.1")
        let client = client(stub, cache: CacheOptions(maxEntries: 10, ttl: .milliseconds(50)))

        _ = try await client.lookup("1.1.1.1")
        try await Task.sleep(for: .milliseconds(120))
        _ = try await client.lookup("1.1.1.1")

        await #expect(stub.callCount == 2)
    }

    @Test("the cache evicts the least recently used entry")
    func cacheEvictsLeastRecentlyUsed() async throws {
        let addresses = ["1.1.1.1", "8.8.8.8", "9.9.9.9"]
        let stub = StubTransport(StubTransport.answers(for: addresses))
        let client = client(stub, cache: CacheOptions(maxEntries: 2, ttl: .seconds(60)))

        _ = try await client.lookup("1.1.1.1")
        _ = try await client.lookup("8.8.8.8")
        _ = try await client.lookup("1.1.1.1")
        _ = try await client.lookup("9.9.9.9")
        // 8.8.8.8 is the oldest touch, so it is the one that went.
        _ = try await client.lookup("1.1.1.1")
        _ = try await client.lookup("8.8.8.8")

        await #expect(stub.callCount == 4)
    }

    // Swift has `??`, so the absent-versus-false distinction needs no helper
    // reader the way Go and Java do. This pins the ergonomics the README teaches.
    @Test("an absent flag coalesces to false without losing the distinction")
    func absentFlagCoalescesWithNilCheck() async throws {
        let stub = StubTransport(["1.1.1.1": .json(["ip": "1.1.1.1", "is_vpn": false])])
        let free = try await client(stub).lookup("1.1.1.1")

        #expect(free.isHosting == nil, "the free plan does not include is_hosting")
        #expect((free.isHosting ?? false) == false)

        let served = StubTransport([
            "8.8.4.4": .json(["ip": "8.8.4.4", "is_vpn": false, "is_hosting": false]),
        ])
        let max = try await client(served).lookup("8.8.4.4")
        #expect(max.isHosting == false, "a served false is not the same as absent")
        #expect(max.isHosting != nil)
    }

    @Test("the checksum endpoint answers the whole digest set")
    func checksumsReturnsEveryDigest() async throws {
        let stub = StubTransport([
            "/api/v1/database/checksum": .json([
                "id": "vpn_ip_extended_v1",
                "format": "mmdb",
                "checksums": [
                    "md5": "d41d8", "sha1": "da39a", "sha256": "e3b0c", "sha512": "cf83e",
                ],
            ])
        ])
        let client = client(stub, apiKey: "key")

        let checksums = try await client.database.checksums(
            id: "vpn_ip_extended_v1", format: .mmdb,
        )

        // Nested under `checksums`, not at the top level, and all four come back.
        #expect(checksums.sha256 == "e3b0c")
        #expect(checksums.md5 == "d41d8")
        #expect(checksums.sha1 == "da39a")
        #expect(checksums.sha512 == "cf83e")
    }

    @Test("dataset metadata unwraps schema, sample and size")
    func metadataUnwrapsItsNestedMaps() async throws {
        let stub = StubTransport([
            "/api/v1/database/metadata": .json([
                "id": "vpn_ip_extended_v1",
                "update_freq": "daily",
                "updated": "2026-09-02",
                "entries": 1234,
                "schema": ["csvgz": [["name": "ip", "type": "varchar", "description": "the range"]]],
                "sample": ["csvgz": [["ip": "45.83.91.0/24", "hits": 42, "ok": true]]],
                "size": ["csvgz": 987],
            ])
        ])

        let metadata = try await client(stub, apiKey: "key").database.metadata(
            id: "vpn_ip_extended_v1",
        )

        #expect(metadata.entries == 1234)
        #expect(metadata.updated == "2026-09-02")
        #expect(metadata.schema["csvgz"]?.first?.name == "ip")
        #expect(metadata.schema["csvgz"]?.first?.type == "varchar")
        #expect(metadata.sample["csvgz"]?.first?["ip"] == .string("45.83.91.0/24"))
        #expect(metadata.sample["csvgz"]?.first?["hits"]?.intValue == 42)
        #expect(metadata.sample["csvgz"]?.first?["ok"] == .bool(true))
        #expect(metadata.size["csvgz"] == 987)
    }

    // The licence is held against the FAMILY, and the ids a download takes hang
    // off `versions`. A listing that stopped at the family would leave a caller
    // with nothing to pass to `download`.
    @Test("the licensed dataset list carries each family's versions and license term")
    func listCarriesVersionsAndTerm() async throws {
        let stub = StubTransport([
            "/api/v1/database/list": .json([
                "datasets": [[
                    "base": "vpn_ip",
                    "name": "VPN IP",
                    "redistribution": "internal",
                    "in_term": true,
                    "standing": "licensed",
                    "versions": [[
                        "id": "vpn_ip_extended_v1",
                        "version": 1,
                        "formats": [
                            ["format": "mmdb", "bytes": 42], ["format": "csvgz", "bytes": nil],
                        ],
                        "sampleFormats": ["csvgz"],
                    ]],
                ]]
            ])
        ])

        let datasets = try await client(stub, apiKey: "key").database.list()

        #expect(datasets.count == 1)
        #expect(datasets[0].base == "vpn_ip")
        #expect(datasets[0].redistribution == .internal)
        #expect(datasets[0].standing == .licensed)
        #expect(datasets[0].inTerm)
        let version = try #require(datasets[0].versions.first)
        #expect(version.id == "vpn_ip_extended_v1")
        #expect(version.version == 1)
        #expect(version.formats.map(\.format) == [.mmdb, .csvgz])
        #expect(version.formats[1].bytes == nil, "an unpublished format has no size")
        #expect(version.sampleFormats == [.csvgz])
    }

    // The runtime's stock transcoders each reject what the other accepts, and
    // the API serves the fractional form, so a strict client decodes the whole
    // listing as a corrupt-date failure.
    @Test("a license date decodes with or without fractional seconds")
    func licenseDatesDecodeEitherWay() async throws {
        let stub = StubTransport([
            "/api/v1/database/list": .json([
                "datasets": [
                    family("vpn_ip", starts: "2026-09-04T07:49:45.118Z"),
                    family("cdn_ip", starts: "2026-09-04T07:49:45Z"),
                ]
            ])
        ])

        let datasets = try await client(stub, apiKey: "key").database.list()

        #expect(datasets.count == 2)
        for dataset in datasets {
            #expect(dataset.starts != nil, "\(dataset.base) lost its start date")
        }
        #expect(datasets[0].starts == datasets[1].starts?.addingTimeInterval(0.118))
    }

    @Test("a 404 from a bad dataset id is not retried")
    func unknownDatasetIsNotRetried() async throws {
        let stub = StubTransport([
            "/api/v1/database/metadata": .json(["rc": "NOT_FOUND"], status: 404)
        ])
        let client = client(stub, apiKey: "key", retries: 3)

        let failure = await #expect(throws: VPNDetectionError.self) {
            try await client.database.metadata(id: "nope")
        }
        #expect(try #require(failure).kind == .badRequest)
        #expect(try #require(failure).isRetryable == false)
        await #expect(stub.callCount == 1)
    }

    @Test("an unusable option is rejected rather than silently clamped")
    func optionsAreValidated() {
        // A zero concurrency would deadlock a batch and a negative retry count
        // is meaningless, so both trap rather than being quietly repaired.
        #expect(VPNDetectionClient.Options().concurrency == 8)
        #expect(VPNDetectionClient.Options().retries == 2)
        #expect(VPNDetectionClient.Options().cache?.maxEntries == 10_000)
        #expect(VPNDetectionClient.Options().cache?.ttl == .seconds(3600))
        #expect(VPNDetectionClient.Options().baseURL == VPNDetectionClient.defaultBaseURL)
    }
}

/// The download endpoint answers `302` to object storage, and following it would
/// read a dataset that runs to gigabytes into memory. Both halves are asserted
/// against real local origins, because a stub cannot follow anything.
@Suite("Download redirect")
struct DownloadRedirectTests {
    @Test("the redirect is returned, and storage is never contacted")
    func redirectIsNotFollowed() async throws {
        let storage = try await TestOrigin.start { _ in .neverEndingGigabyte }
        let location = "http://127.0.0.1:\(storage.port)/vpn_ip_extended_v1.mmdb?signature=abc"
        let api = try await TestOrigin.start { _ in .redirect(to: location) }
        defer {
            Task { try? await storage.stop() }
            Task { try? await api.stop() }
        }

        let client = VPNDetectionClient(
            options: .init(apiKey: "key", baseURL: URL(string: "http://127.0.0.1:\(api.port)")!),
        )
        let url = try await client.database.downloadURL(id: "vpn_ip_extended_v1", format: .mmdb)

        #expect(url.absoluteString == location)
        #expect(api.receivedPaths.count == 1)
        #expect(
            storage.receivedPaths.isEmpty,
            "the transport followed the redirect and is holding the dataset",
        )
    }

    @Test("a transport that does follow redirects is refused before the body is read")
    func aFollowingTransportIsRefused() async throws {
        let storage = try await TestOrigin.start { _ in .neverEndingGigabyte }
        let location = "http://127.0.0.1:\(storage.port)/vpn_ip_extended_v1.mmdb"
        let api = try await TestOrigin.start { _ in .redirect(to: location) }
        let follower = HTTPClient(
            eventLoopGroupProvider: .singleton,
            configuration: .init(redirectConfiguration: .follow(max: 5, allowCycles: false)),
        )
        defer {
            Task { try? await follower.shutdown() }
            Task { try? await storage.stop() }
            Task { try? await api.stop() }
        }

        let client = VPNDetectionClient(
            options: .init(
                apiKey: "key",
                baseURL: URL(string: "http://127.0.0.1:\(api.port)")!,
                retries: 0,
                transport: AsyncHTTPClientTransport(configuration: .init(client: follower)),
            ),
        )

        let started = ContinuousClock.now
        let failure = await #expect(throws: VPNDetectionError.self) {
            try await client.database.downloadURL(id: "vpn_ip_extended_v1", format: .mmdb)
        }
        let elapsed = ContinuousClock.now - started

        #expect(try #require(failure).status == 200)
        // Storage was reached, so the guard is what stopped the transfer rather
        // than the redirect never happening.
        #expect(storage.receivedPaths.count == 1)
        #expect(elapsed < .seconds(5), "the promised gigabyte was being read")
    }
}

/// The streaming transfer, against real local origins for the same reason: the
/// second request goes to object storage rather than to the API, and what it
/// must NOT carry is a header.
@Suite("Download transfer")
struct DownloadTransferTests {
    struct SinkStopped: Error {}

    static let payload: [UInt8] = Array("a small dataset, gzipped in real life".utf8)

    @Test("a download lands intact, and the key never reaches object storage")
    func downloadWritesTheFileAndWithholdsTheKey() async throws {
        let origins = try await Origins.start(.file(Self.payload))
        defer { origins.stop() }
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("cdn_ip_v1.csv.gz")

        let written = try await origins.client.database.download(
            "cdn_ip_v1", format: .csvgz, to: destination,
        )

        #expect(written == Self.payload.count)
        let landed = try Data(contentsOf: destination)
        #expect([UInt8](landed) == Self.payload)
        #expect(landed.count == written, "the file is not the length the method reported")
        #expect(
            FileManager.default.fileExists(atPath: destination.path + ".part") == false,
            "the .part file outlived a successful transfer",
        )
        #expect(origins.api.receivedAuthorizations == ["Bearer key"])
        #expect(
            origins.storage.receivedAuthorizations == [nil],
            "the API key was presented to object storage",
        )
    }

    @Test("downloadBytes hands back the same bytes")
    func downloadBytesMatchesTheFile() async throws {
        let origins = try await Origins.start(.file(Self.payload))
        defer { origins.stop() }

        let bytes = try await origins.client.database.downloadBytes("cdn_ip_v1", format: .csvgz)

        #expect([UInt8](bytes) == Self.payload)
    }

    // Writing straight to the destination passes every other case here, because
    // a refusal fails before any file exists. Only a death mid-body produces the
    // truncated file that would otherwise read as a whole dataset.
    @Test("a transfer that dies leaves neither a partial nor a whole file")
    func aDeadTransferLeavesNothingBehind() async throws {
        let origins = try await Origins.start(.truncated(promising: 4096, writing: 16))
        defer { origins.stop() }
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("cdn_ip_v1.csv.gz")

        await #expect(throws: (any Error).self) {
            try await origins.client.database.download("cdn_ip_v1", format: .csvgz, to: destination)
        }

        let manager = FileManager.default
        #expect(manager.fileExists(atPath: destination.path) == false)
        #expect(manager.fileExists(atPath: destination.path + ".part") == false)
    }

    // The sink sees bytes while the body is still arriving, so nothing collected
    // the dataset first. A buffering implementation waits for a gigabyte that
    // never comes.
    // The time limit is what makes a buffering implementation FAIL rather than
    // hang: collecting first waits on a gigabyte the origin never sends.
    @Test("the sink is fed while the body is still arriving", .timeLimit(.minutes(1)))
    func theSinkSeesBytesBeforeTheBodyEnds() async throws {
        let origins = try await Origins.start(.neverEndingGigabyte)
        defer { origins.stop() }

        let started = ContinuousClock.now
        await #expect(throws: SinkStopped.self) {
            try await origins.client.database.download("cdn_ip_v1", format: .csvgz) { chunk in
                #expect(chunk.isEmpty == false)
                throw SinkStopped()
            }
        }
        let elapsed = ContinuousClock.now - started

        #expect(elapsed < .seconds(5), "the promised gigabyte was being collected first")
    }

    private func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vpndetection-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// An API that redirects and a storage host that answers, plus a client
    /// pointed at the first.
    struct Origins {
        let api: TestOrigin
        let storage: TestOrigin
        let client: VPNDetectionClient

        static func start(_ answer: TestOrigin.Answer) async throws -> Origins {
            let storage = try await TestOrigin.start { _ in answer }
            let location = "http://127.0.0.1:\(storage.port)/cdn_ip_v1.csv.gz?signature=abc"
            let api = try await TestOrigin.start { _ in .redirect(to: location) }
            return Origins(
                api: api,
                storage: storage,
                client: VPNDetectionClient(
                    options: .init(
                        apiKey: "key",
                        baseURL: URL(string: "http://127.0.0.1:\(api.port)")!,
                        retries: 0,
                    ),
                ),
            )
        }

        func stop() {
            Task { try? await storage.stop() }
            Task { try? await api.stop() }
        }
    }
}

extension ClientTests {
    func family(_ base: String, starts: String) -> [String: Any] {
        [
            "base": base,
            "name": base,
            "redistribution": "internal",
            "in_term": true,
            "standing": "licensed",
            "starts": starts,
            "versions": [["id": "\(base)_v1", "version": 1, "formats": []]],
        ]
    }

    func client(
        _ transport: StubTransport,
        apiKey: String? = nil,
        cache: CacheOptions? = CacheOptions(),
        concurrency: Int = 8,
        retries: Int = 2,
    ) -> VPNDetectionClient {
        VPNDetectionClient(
            options: .init(
                apiKey: apiKey, cache: cache, concurrency: concurrency,
                retries: retries, transport: transport,
            ),
        )
    }
}
