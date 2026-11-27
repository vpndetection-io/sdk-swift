import Foundation
import Testing

@testable import VPNDetection

// Unlimited's answer stopped carrying the AS's `type` on 2026-11-26: it is a paid
// plan's. `Asn.type` stays a `String`, so an answer without it reads empty, one
// with it reads as served, and a `type` that is no string is refused as it was
// while the member was required.
@Suite("The AS's type, a paid plan's")
struct AsnTypeTests {
    nonisolated(unsafe) static let served: [String: Any] = [
        "asn": 9009, "name": "M247 Europe SRL", "domain": "m247global.com", "type": "hosting",
        "prefix": "146.70.116.0/24", "country": "RO", "rpki_status": "valid",
    ]

    @Test("an answer without it reads it empty and the rest as served, on every lookup")
    func absentReadsEmpty() async throws {
        var unlimited = Self.served
        unlimited.removeValue(forKey: "type")
        let stub = StubTransport([
            "45.83.91.1": .json(Self.answer(unlimited)), "myip": .json(Self.answer(unlimited, "45.83.91.9")),
            "45.83.91.2": .json(Self.answer(unlimited, "45.83.91.2")),
            "45.83.91.3": .json(Self.answer(unlimited, "45.83.91.3")),
        ])
        let client = Self.client(stub)

        let batch = try await client.lookupBatch(["45.83.91.2", "45.83.91.3"])
        let results = [
            try await client.lookup("45.83.91.1"), try await client.myIP(),
            try #require(batch["45.83.91.2"]).get(), try #require(batch["45.83.91.3"]).get(),
        ]
        for result in results {
            let asn = try #require(result.asn, "the answer of \(result.ip) carries an asn")
            #expect(asn.type == "", "type of \(result.ip)")
            #expect(asn.asn == 9009 && asn.name == "M247 Europe SRL" && asn.domain == "m247global.com")
            #expect(asn.prefix == "146.70.116.0/24" && asn.country == "RO" && asn.rpkiStatus == "valid")
        }

        let before = await stub.callCount
        #expect(try await client.lookup("45.83.91.1").asn?.type == "", "the cached answer reads the same")
        await #expect(stub.callCount == before, "the second lookup came from the cache")
    }

    @Test("a served one reads as served")
    func presentReadsAsServed() async throws {
        for kind in ["isp", "hosting", "education", "government", "business", ""] {
            var asn = Self.served
            asn["type"] = kind
            let stub = StubTransport(["45.83.91.1": .json(Self.answer(asn))])

            let result = try await Self.client(stub).lookup("45.83.91.1")

            #expect(result.asn?.type == kind, "type served as \(kind.debugDescription)")
        }
    }

    // A null is the member present and wrong, which the generated Optional would
    // have read as absent: a retried server error, a batch entry's alone.
    @Test("one served as anything but a string is a retried server error, a batch entry's alone")
    func aPresentTypeOfAnotherTypeIsRefused() async throws {
        let wrong: [(String, Any)] = [
            ("null", NSNull()), ("1", 1), ("true", true), ("[]", [Any]()), ("{}", [String: Any]()),
        ]
        for (shown, value) in wrong {
            let label = "type of \(shown)"
            var asn = Self.served
            asn["type"] = value
            let single = StubTransport(["45.83.91.1": .json(Self.answer(asn))])
            let failure = await #expect(throws: VPNDetectionError.self, "\(label)") {
                try await Self.client(single, retries: 2).lookup("45.83.91.1")
            }
            #expect(failure?.kind == .serverError, "\(label)")
            #expect(failure?.status == 200, "\(label)")
            #expect(failure?.isRetryable == true, "\(label)")
            await #expect(single.callCount == 3, "\(label): retried")

            let batch = StubTransport(["batch": .json([
                "results": ["45.83.91.1": Self.answer(asn), "45.83.91.2": Self.answer(Self.served, "45.83.91.2")],
                "errors": [String: Any](),
            ])])
            let results = try await Self.client(batch, retries: 2).lookupBatch(["45.83.91.1", "45.83.91.2"])
            guard case .failure(let error) = results["45.83.91.1"], case .success = results["45.83.91.2"] else {
                Issue.record("\(label): the batch entry came back as an answer, or the one beside it failed")
                continue
            }
            #expect(error.kind == .serverError && error.status == 200, "\(label): batch")
            await #expect(batch.callCount == 1, "\(label): a batch entry is not sent again")
        }
    }

    @Test("leaving the type out relaxes no other member")
    func theOthersStayRequired() async throws {
        for member in ["asn", "name", "domain", "prefix", "country", "rpki_status"] {
            var asn = Self.served
            asn.removeValue(forKey: "type")
            asn.removeValue(forKey: member)
            let stub = StubTransport(["45.83.91.1": .json(Self.answer(asn))])

            let failure = await #expect(throws: VPNDetectionError.self, "without type and \(member)") {
                try await Self.client(stub, retries: 0).lookup("45.83.91.1")
            }

            #expect(failure?.kind == .serverError, "without type and \(member)")
        }
    }

    static func answer(_ asn: [String: Any], _ ip: String = "45.83.91.1") -> [String: Any] {
        ["ip": ip, "is_vpn": true, "asn": asn]
    }

    static func client(_ stub: StubTransport, retries: Int = 2) -> VPNDetectionClient {
        VPNDetectionClient(options: .init(cache: CacheOptions(), retries: retries, transport: stub))
    }
}
