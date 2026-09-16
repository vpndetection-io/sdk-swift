import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import VPNDetection

/// The per-call timeout, which bounds each ATTEMPT. Every stall is a real socket
/// that took the request, and every failure is checked for having taken at least
/// the timeout: a refused connection is a retryable network error too, and would
/// otherwise pass for the deadline firing.
@Suite("Timeout")
struct TimeoutTests {
    static let perCall: Duration = .milliseconds(250)
    /// Timer slack, so a deadline that fired a hair early is not read as none.
    static let atLeast: Duration = .milliseconds(200)

    enum Call: String, CaseIterable, Sendable {
        case lookup, myIP, myEntitlement, batch
    }

    // The default transport's own bound is 60 seconds to the response head, so a
    // failure inside a few seconds is the per-call value firing.
    @Test("a per-call timeout fires as a retryable network error", arguments: Call.allCases)
    func perCallTimeoutFires(_ call: Call) async throws {
        let origin = try await TestOrigin.start { _ in .silence }
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
    @Test("a body that stalls after its head is bounded too", .timeLimit(.minutes(1)))
    func aStalledBodyIsBounded() async throws {
        let origin = try await TestOrigin.start { _ in .stalledLookup }
        defer { Task { try? await origin.stop() } }
        let client = Self.client(origin)

        let failure = await #expect(throws: VPNDetectionError.self) {
            try await client.lookup("9.9.9.9", timeout: Self.perCall)
        }

        #expect(try #require(failure).kind == .network)
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

    static func client(_ origin: TestOrigin, retries: Int = 0) -> VPNDetectionClient {
        VPNDetectionClient(
            options: .init(
                baseURL: URL(string: "http://127.0.0.1:\(origin.port)")!, cache: nil, retries: retries,
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
