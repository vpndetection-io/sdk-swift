import Foundation
import Testing

@testable import VPNDetection

// Through 4.10.2 a per-call count below zero was read as none, so a failing call
// was sent once, and a bogon, a cached address or a bogon-only batch answered it.
@Suite("A per-call retry count")
struct RetryCountTests {
    @Test("below zero is refused before anything answers")
    func belowZeroIsRefused() async throws {
        let stub = StubTransport.answering("8.8.8.8")
        let client = VPNDetectionClient(options: .init(apiKey: "key", transport: stub))
        _ = try await client.lookup("8.8.8.8")
        for value in [-1, -5, Int.min] {
            let calls: [(String, @Sendable () async throws -> Void)] = [
                ("a bogon", { _ = try await client.lookup("10.0.0.1", retries: value) }),
                ("a cached address", { _ = try await client.lookup("8.8.8.8", retries: value) }),
                ("an address to look up", { _ = try await client.lookup("9.9.9.9", retries: value) }),
                ("myIP", { _ = try await client.myIP(retries: value) }),
                ("myEntitlement", { _ = try await client.myEntitlement(retries: value) }),
                ("a batch", {
                    _ = try await client.lookupBatch(["10.0.0.1", "9.9.9.9"], options: .init(retries: value))
                }),
                ("a batch answered locally", {
                    _ = try await client.lookupBatch(["10.0.0.1", "8.8.8.8"], options: .init(retries: value))
                }),
            ]
            for (name, call) in calls {
                let error = await #expect(throws: VPNDetectionError.self, "\(name), retries \(value)") {
                    try await call()
                }
                #expect(error?.kind == .badRequest, "\(name), retries \(value)")
            }
        }
        await #expect(stub.callCount == 1, "no refused count reached the network")
        _ = try await client.lookup("8.8.8.8", retries: 0)
    }
}
