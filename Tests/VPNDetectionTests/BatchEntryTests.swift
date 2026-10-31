import Foundation
import Testing

@testable import VPNDetection

// Through 4.10.2 the generated decoder read a chunk's whole answer, so one entry
// it could not read failed every address in the chunk, sent three times.
@Suite("A batch answer read entry by entry")
struct BatchEntryTests {
    nonisolated(unsafe) static let good: [String: Any] = ["ip": "45.83.91.2", "is_vpn": true, "vpn": ["provider": "mullvad"]]

    @Test("an entry it cannot read fails that address alone, sent once")
    func anUnreadableEntryFailsThatAddressAlone() async throws {
        let entries: [(String, Any)] = [
            ("dcproxy.hits of \"3\"", ["ip": "45.83.91.1", "is_vpn": true, "dcproxy": ["hits": "3"]]),
            ("is_vpn of \"yes\"", ["ip": "45.83.91.1", "is_vpn": "yes"]),
            ("pubproxy.protocols of [null]", ["ip": "45.83.91.1", "is_vpn": true, "pubproxy": ["protocols": [NSNull()]]]),
            ("an entry of {}", [String: Any]()),
            ("an entry of null", NSNull()),
            ("an entry of \"x\"", "x"),
        ]
        for (name, entry) in entries {
            let stub = Self.serving(["results": ["45.83.91.1": entry, "45.83.91.2": Self.good], "errors": [:]])
            let results = try await Self.client(stub).lookupBatch(["45.83.91.1", "45.83.91.2"])
            Self.expectUnreadable(results["45.83.91.1"], name)
            guard case .success(let served) = results["45.83.91.2"] else {
                Issue.record("the good entry beside \(name) failed")
                continue
            }
            #expect(served.vpn?.provider == "mullvad", "\(name)")
            await #expect(stub.callCount == 1, "\(name)")
        }
    }

    @Test("an entry error it cannot read fails that address alone, sent once")
    func anUnreadableEntryErrorFailsThatAddressAlone() async throws {
        let entries: [(String, Any)] = [
            ("a status of \"x\"", ["status": "x", "error": "failed"]),
            ("an error of null", NSNull()),
            ("an error of []", [Any]()),
        ]
        for (name, entry) in entries {
            let stub = Self.serving(["results": ["45.83.91.2": Self.good], "errors": ["45.83.91.1": entry]])
            let results = try await Self.client(stub).lookupBatch(["45.83.91.1", "45.83.91.2"])
            Self.expectUnreadable(results["45.83.91.1"], name)
            guard case .success = results["45.83.91.2"] else {
                Issue.record("the good entry beside \(name) failed")
                continue
            }
            await #expect(stub.callCount == 1, "\(name)")
        }
        let stub = Self.serving(["results": [:], "errors": ["45.83.91.1": ["status": 404, "error": "not found"]]])
        let results = try await Self.client(stub).lookupBatch(["45.83.91.1"])
        guard case .failure(let error) = results["45.83.91.1"] else {
            Issue.record("a readable entry error came back as an answer")
            return
        }
        #expect(error.kind == .badRequest)
        #expect(error.status == 404)
    }

    @Test("a chunk holding neither map fails every address in it, retried")
    func aChunkHoldingNeitherMapFailsEveryAddress() async throws {
        let bodies: [(String, Data)] = [
            ("{}", Data("{}".utf8)),
            ("[]", Data("[]".utf8)),
            ("null", Data("null".utf8)),
            ("an HTML page", Data("<html>gateway</html>".utf8)),
            ("results of []", Data(#"{"results":[],"errors":{}}"#.utf8)),
            ("a cut-off body", Data(#"{"results":{"45.83.91.2":{"ip":"#.utf8)),
        ]
        for (name, body) in bodies {
            let stub = StubTransport(["batch": .init(status: 200, body: body)])
            let results = try await Self.client(stub).lookupBatch(["45.83.91.1", "45.83.91.2"])
            Self.expectUnreadable(results["45.83.91.1"], name)
            Self.expectUnreadable(results["45.83.91.2"], name)
            await #expect(stub.callCount == 3, "\(name)")
        }
    }

    @Test("one map alone is read, an address in neither a server error")
    func oneMapAloneIsRead() async throws {
        let stub = Self.serving(["results": ["45.83.91.2": Self.good]])
        let results = try await Self.client(stub).lookupBatch(["45.83.91.1", "45.83.91.2"])
        guard case .success = results["45.83.91.2"] else {
            Issue.record("a chunk without errors lost its result")
            return
        }
        Self.expectUnreadable(results["45.83.91.1"], "an address in neither map")
        await #expect(stub.callCount == 1)
    }

    static func serving(_ body: [String: Any]) -> StubTransport {
        StubTransport(["batch": .json(body)])
    }

    static func client(_ stub: StubTransport) -> VPNDetectionClient {
        VPNDetectionClient(options: .init(apiKey: "key", cache: nil, retries: 2, transport: stub))
    }

    static func expectUnreadable(_ outcome: BatchResults.Outcome?, _ name: String) {
        guard case .failure(let error) = outcome else {
            Issue.record("\(name) came back as an answer")
            return
        }
        #expect(error.kind == .serverError, "\(name)")
        #expect(error.status == 200, "\(name)")
    }
}
