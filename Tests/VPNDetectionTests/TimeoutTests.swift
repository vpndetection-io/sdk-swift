import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import VPNDetection

/// The client's timeout and the per-call one, each bounding a whole ATTEMPT. Every
/// stall is a real socket that took the request, and every failure is checked for
/// having taken at least the timeout: a refused connection is a retryable network
/// error too, and would otherwise pass for the deadline firing.
@Suite("Timeout")
struct TimeoutTests {
    static let perCall: Duration = .milliseconds(250)
    /// Timer slack, so a deadline that fired a hair early is not read as none.
    static let atLeast: Duration = .milliseconds(200)

    enum Call: String, CaseIterable, Sendable {
        case lookup, myIP, myEntitlement, batch
    }

    /// The database calls that ask the API a question. The transfers are absent
    /// because they take no per-call timeout at all, which
    /// ``onlyTheJSONDatabaseCallsTakeATimeout()`` is what asserts.
    enum DatabaseCall: String, CaseIterable, Sendable {
        case list, metadata, checksums, downloads, downloadURL
    }

    // The client keeps its 30 second default, so a failure inside a few seconds is
    // the per-call value firing, and on a body that stalled after its head.
    @Test("a per-call timeout fires as a retryable network error", arguments: Call.allCases)
    func perCallTimeoutFires(_ call: Call) async throws {
        let origin = try await TestOrigin.start { _ in .stalledLookup }
        defer { Task { try? await origin.stop() } }
        let client = Self.client(origin)

        let started = ContinuousClock.now
        let failure = try await Self.failure(of: call, on: client)
        let elapsed = ContinuousClock.now - started

        #expect(failure.kind == .network)
        #expect(failure.isRetryable)
        #expect(failure.message.hasPrefix("the request timed out"), "\(failure.message)")
        #expect(elapsed >= Self.atLeast, "failed after \(elapsed), before the deadline could fire")
        #expect(elapsed < .seconds(10))
        #expect(origin.receivedPaths.count == 1)
    }

    @Test("each retry gets the whole timeout again")
    func eachRetryGetsTheWholeTimeout() async throws {
        let origin = try await TestOrigin.start { _ in .silence }
        defer { Task { try? await origin.stop() } }
        let client = Self.client(origin, retries: 1)

        let started = ContinuousClock.now
        await #expect(throws: VPNDetectionError.self) {
            try await client.lookup("9.9.9.9", timeout: Self.perCall)
        }

        #expect(origin.receivedPaths.count == 2)
        #expect(ContinuousClock.now - started >= Self.atLeast * 2)
    }

    // The transport's own bound ends when the head arrives, so nothing else would
    // ever end this call.
    @Test("the client's own timeout bounds a body that stalls after its head", .timeLimit(.minutes(1)))
    func aStalledBodyIsBounded() async throws {
        let origin = try await TestOrigin.start { _ in .stalledLookup }
        defer { Task { try? await origin.stop() } }
        let client = Self.client(origin, timeout: .milliseconds(300))

        let started = ContinuousClock.now
        let failure = await #expect(throws: VPNDetectionError.self) {
            try await client.lookup("9.9.9.9")
        }

        #expect(try #require(failure).kind == .network)
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    // No single read waits more than 20 ms, so only a bound on the whole attempt
    // can end this before the answer completes at about 620 ms.
    @Test("a trickled body is bounded as a whole, not per read", .timeLimit(.minutes(1)))
    func aTrickledBodyIsBoundedAsAWhole() async throws {
        let origin = try await TestOrigin.start { _ in .trickledLookup }
        defer { Task { try? await origin.stop() } }
        let client = Self.client(origin, timeout: .milliseconds(300))

        let started = ContinuousClock.now
        let failure = await #expect(throws: VPNDetectionError.self) {
            try await client.lookup("9.9.9.9")
        }

        #expect(try #require(failure).kind == .network)
        #expect(ContinuousClock.now - started >= Self.atLeast)
    }

    // A per-call value written into the client would pass the first call and fail
    // the second.
    @Test(
        "a per-call timeout lengthens the client's, and leaves it for the next call", .timeLimit(.minutes(1)),
    )
    func aPerCallTimeoutLengthensTheClients() async throws {
        let origin = try await TestOrigin.start { _ in .trickledLookup }
        defer { Task { try? await origin.stop() } }
        let client = Self.client(origin, timeout: .milliseconds(300))

        let result = try await client.lookup("9.9.9.9", timeout: .seconds(10))
        let failure = await #expect(throws: VPNDetectionError.self) {
            try await client.myIP()
        }

        #expect(result.ip == "9.9.9.9")
        #expect(try #require(failure).kind == .network)
    }

    @Test("the client's timeout bounds a database call", .timeLimit(.minutes(1)))
    func aDatabaseCallIsBounded() async throws {
        let origin = try await TestOrigin.start { _ in .stalledLookup }
        defer { Task { try? await origin.stop() } }
        let client = Self.client(origin, timeout: .milliseconds(300))

        let started = ContinuousClock.now
        let failure = await #expect(throws: VPNDetectionError.self) {
            try await client.database.list()
        }

        #expect(try #require(failure).kind == .network)
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    // The client keeps its 30 second default, so only the per-call value can end
    // any of these. The head lands at once and the body then arrives a byte at a
    // time, so no single read ever waits long enough to be what fired; the
    // redirect has no body to trickle, so its origin never answers at all.
    @Test(
        "a per-call timeout bounds every database call", .timeLimit(.minutes(1)),
        arguments: DatabaseCall.allCases,
    )
    func aPerCallTimeoutBoundsEveryDatabaseCall(_ call: DatabaseCall) async throws {
        let origin = try await TestOrigin.start { _ in
            call == .downloadURL ? .silence : .trickledListing
        }
        defer { Task { try? await origin.stop() } }
        let client = Self.client(origin)

        let started = ContinuousClock.now
        let failure = try await Self.failure(of: call, on: client, timeout: Self.perCall)
        let elapsed = ContinuousClock.now - started

        #expect(failure.kind == .network)
        #expect(failure.isRetryable)
        #expect(failure.message.hasPrefix("the request timed out"), "\(failure.message)")
        #expect(elapsed >= Self.atLeast, "failed after \(elapsed), before the deadline could fire")
        // Under the listing's own thousand milliseconds, so a per-call value that
        // was accepted and ignored cannot pass by the body simply finishing.
        #expect(elapsed < .milliseconds(900), "failed after \(elapsed), not at the per-call deadline")
        #expect(origin.receivedPaths.count == 1)
    }

    // A per-call value kept anywhere but the call itself - written into the client,
    // or into the API struct it is reached through - passes the first of these and
    // fails the second.
    @Test(
        "a database call with no timeout falls back to the client's", .timeLimit(.minutes(1)),
    )
    func aDatabaseCallWithoutAnOverrideUsesTheClients() async throws {
        let origin = try await TestOrigin.start { _ in .trickledListing }
        defer { Task { try? await origin.stop() } }
        let client = Self.client(origin, timeout: .milliseconds(300))

        let databases = try await client.database.list(timeout: .seconds(10))
        let started = ContinuousClock.now
        let failure = await #expect(throws: VPNDetectionError.self) {
            try await client.database.downloads()
        }
        let elapsed = ContinuousClock.now - started

        #expect(databases.isEmpty)
        #expect(try #require(failure).kind == .network)
        #expect(elapsed >= Self.atLeast, "failed after \(elapsed), before the client's deadline could fire")
        #expect(elapsed < .milliseconds(900), "failed after \(elapsed), not at the client's timeout")
    }

    // A method reference names every parameter and never applies a default, so
    // the annotations below ARE the signatures. A `timeout` added to a transfer,
    // or dropped from a call that asks the API a question, stops this file
    // compiling - which is how Swift refuses the option rather than accepting it
    // and quietly doing nothing with it.
    @Test("every JSON database call takes a per-call timeout, and no transfer does")
    func onlyTheJSONDatabaseCallsTakeATimeout() async throws {
        let stub = StubTransport(["/api/v1/database/list": .json(["databases": []])])
        let client = VPNDetectionClient(options: .init(cache: nil, transport: stub))

        let list: (Duration?) async throws -> [Database] = client.database.list(timeout:)
        let metadata: (String, Duration?) async throws -> DatabaseMetadata =
            client.database.metadata(id:timeout:)
        let checksums: (String, DatabaseFormat, Duration?) async throws -> DbChecksums =
            client.database.checksums(id:format:timeout:)
        let downloads: (Int?, Duration?) async throws -> [Download] =
            client.database.downloads(limit:timeout:)
        let downloadURL: (String, DatabaseFormat, Duration?) async throws -> URL =
            client.database.downloadURL(id:format:timeout:)

        let toFile: (String, DatabaseFormat, URL) async throws -> Int64 =
            client.database.download(_:format:to:)
        let toSink: (String, DatabaseFormat, DownloadSink) async throws -> Int64 =
            client.database.download(_:format:to:)
        let toBytes: (String, DatabaseFormat) async throws -> Data =
            client.database.downloadBytes(_:format:)

        // One of them is called, so these are live code rather than a comment the
        // compiler happens to check.
        #expect(try await list(.seconds(5)).isEmpty)
        #expect(await stub.callCount == 1)
        _ = (metadata, checksums, downloads, downloadURL, toFile, toSink, toBytes)
    }

    // Cancelling releases the connection, but only a transport that HONORS
    // cancellation then returns, and a supplied one need not.
    @Test("a transport that ignores cancellation is still bounded", .timeLimit(.minutes(1)))
    func aDeafTransportIsStillBounded() async throws {
        let client = VPNDetectionClient(
            options: .init(cache: nil, retries: 0, transport: DeafTransport()),
        )

        let started = ContinuousClock.now
        let failure = await #expect(throws: VPNDetectionError.self) {
            try await client.lookup("9.9.9.9", timeout: Self.perCall)
        }

        #expect(try #require(failure).kind == .network)
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test("cancelling a call with a timeout propagates at once, not at the deadline")
    func cancellingATimedCallPropagates() async throws {
        let stub = StubTransport(StubTransport.answers(for: ["9.9.9.1"]), delay: .seconds(5))
        let client = VPNDetectionClient(options: .init(cache: nil, retries: 0, transport: stub))

        let started = ContinuousClock.now
        let call = Task { try await client.lookup("9.9.9.1", timeout: .seconds(3)) }
        try await Task.sleep(for: .milliseconds(100))
        call.cancel()

        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(ContinuousClock.now - started < .seconds(2), "the cancellation waited for the deadline")
    }

    static func client(
        _ origin: TestOrigin, retries: Int = 0, timeout: Duration = .seconds(30),
    ) -> VPNDetectionClient {
        VPNDetectionClient(
            options: .init(
                baseURL: URL(string: "http://127.0.0.1:\(origin.port)")!, cache: nil, retries: retries,
                timeout: timeout,
            ),
        )
    }

    static func failure(of call: Call, on client: VPNDetectionClient) async throws -> VPNDetectionError {
        let caught: VPNDetectionError?
        switch call {
        case .lookup:
            caught = await #expect(throws: VPNDetectionError.self) {
                try await client.lookup("9.9.9.9", timeout: perCall)
            }
        case .myIP:
            caught = await #expect(throws: VPNDetectionError.self) {
                try await client.myIP(timeout: perCall)
            }
        case .myEntitlement:
            caught = await #expect(throws: VPNDetectionError.self) {
                try await client.myEntitlement(timeout: perCall)
            }
        case .batch:
            let results = try await client.lookupBatch(["9.9.9.9"], options: .init(timeout: perCall))
            guard case .failure(let error) = results["9.9.9.9"] else {
                Issue.record("a chunk that timed out must carry the failure")
                caught = nil
                break
            }
            caught = error
        }
        return try #require(caught)
    }

    static func failure(
        of call: DatabaseCall, on client: VPNDetectionClient, timeout: Duration,
    ) async throws -> VPNDetectionError {
        let caught = await #expect(throws: VPNDetectionError.self) {
            switch call {
            case .list:
                _ = try await client.database.list(timeout: timeout)
            case .metadata:
                _ = try await client.database.metadata(id: "vpn_ip_extended_v1", timeout: timeout)
            case .checksums:
                _ = try await client.database.checksums(
                    id: "vpn_ip_extended_v1", format: .mmdb, timeout: timeout,
                )
            case .downloads:
                _ = try await client.database.downloads(timeout: timeout)
            case .downloadURL:
                _ = try await client.database.downloadURL(
                    id: "vpn_ip_extended_v1", format: .mmdb, timeout: timeout,
                )
            }
        }
        return try #require(caught)
    }
}

/// Answers after 30 seconds whatever happens, cancellation included: a detached
/// task is not cancelled with the task awaiting it.
struct DeafTransport: ClientTransport {
    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
    ) async throws -> (HTTPResponse, HTTPBody?) {
        await Task.detached { try? await Task.sleep(for: .seconds(30)) }.value
        return (HTTPResponse(status: .ok), nil)
    }
}
