import Foundation
import Testing

@testable import VPNDetection

/// Asserts the shared conformance corpus that every VPNDetection SDK asserts.
///
/// The corpus is generated into `testdata/` and is identical across languages, so
/// a behavior that drifts here fails here rather than surfacing as two client
/// libraries quietly disagreeing about the same address.
@Suite("Conformance")
struct ConformanceTests {
    let corpus = Corpus.shared

    @Test("isBogon matches the canonical ranges")
    func isBogonMatchesTheCanonicalRanges() {
        for testCase in corpus.isBogon {
            #expect(
                VPNDetection.isBogon(testCase.ip) == testCase.expect,
                "\(testCase.ip) (\(testCase.why))",
            )
        }
    }

    @Test("a bogon is answered locally in the full max shape")
    func bogonIsAnsweredLocallyInTheFullMaxShape() async throws {
        let stub = StubTransport()
        let client = testClient(stub)

        let result = try await client.lookup("10.0.0.1")

        #expect(result.isBogon)
        #expect(result.ip == "10.0.0.1")
        for name in corpus.bogonResponse.flagsFalse {
            expectFlag(result, name, is: false)
        }
        for name in corpus.bogonResponse.emptyObjects {
            expectDetail(result, name, is: [:])
        }
        await #expect(stub.callCount == 0, "a bogon must not reach the network")
    }

    @Test("lookup preserves absent-versus-false across every plan shape")
    func lookupPreservesAbsentVersusFalse() async throws {
        for testCase in corpus.lookup {
            let ip = testCase.expect.ip
            let stub = StubTransport([ip: .init(status: testCase.status, body: testCase.body.encoded)])
            let result = try await testClient(stub).lookup(ip)

            #expect(result.ip == testCase.expect.ip, "\(testCase.name)")
            #expect(result.isBogon == testCase.expect.isBogon, "\(testCase.name)")

            for (name, want) in testCase.expect.present ?? [:] {
                expectFlag(result, name, is: want, testCase.name)
            }
            for name in testCase.expect.absent ?? [] {
                expectAbsent(result, name, testCase.name)
            }
            for name in testCase.expect.emptyPresent ?? [] {
                expectDetail(result, name, is: [:], testCase.name)
            }
            testCase.expect.vpn.map { expectDetail(result, "vpn", is: $0, testCase.name) }
            testCase.expect.hosting.map { expectDetail(result, "hosting", is: $0, testCase.name) }
            testCase.expect.dcproxy.map { expectDetail(result, "dcproxy", is: $0, testCase.name) }
        }
    }

    @Test("a 429 is classified by Retry-After, not by its status")
    func errorsAreClassifiedByRange() async throws {
        for testCase in corpus.errors {
            let route = StubTransport.Route(
                status: testCase.status, body: testCase.body.encoded, headers: testCase.headers,
            )
            // No retries, so a retryable failure surfaces rather than looping.
            let client = testClient(StubTransport(["1.1.1.1": route]), retries: 0)

            let failure = await #expect(throws: VPNDetectionError.self) {
                try await client.lookup("1.1.1.1")
            }
            guard let error = failure else {
                Issue.record("\(testCase.name): no VPNDetectionError was thrown")
                continue
            }
            #expect(error.kind.rawValue == testCase.expect.kind, "\(testCase.name)")
            #expect(error.isRetryable == testCase.expect.retryable, "\(testCase.name): retryable")
            if let message = testCase.expect.message {
                #expect(error.message == message, "\(testCase.name): message")
            }
            if let seconds = testCase.expect.retryAfterSeconds {
                #expect(error.retryAfter == .seconds(seconds), "\(testCase.name): retryAfter")
            }
        }
    }

    @Test("batch dedupes, short-circuits bogons and keys by address")
    func batchDedupesAndKeysByAddress() async throws {
        let testCase = corpus.batchCase("dedup-bogon-and-order-free-keying")
        let stub = StubTransport.answering("1.1.1.1", "8.8.8.8")

        let results = try await testClient(stub).lookupBatch(testCase.input)

        #expect(results.keys == testCase.expect.keys)
        await #expect(stub.callCount == testCase.expect.httpRequests)
        for ip in testCase.expect.bogonKeys ?? [] {
            #expect(try results[ip]?.get().isBogon == true, "\(ip) should be a local answer")
        }
    }

    @Test("one bad address does not lose the rest of the batch")
    func partialFailureDoesNotFailTheBatch() async throws {
        let testCase = corpus.batchCase("partial-failure-does-not-fail-the-batch")
        let client = testClient(StubTransport.answering("1.1.1.1"), retries: 0)

        let results = try await client.lookupBatch(testCase.input)

        #expect(results.keys == testCase.expect.keys)
        for ip in testCase.expect.errorKeys ?? [] {
            guard case .failure = results[ip] else {
                Issue.record("\(ip) should carry its own error")
                continue
            }
        }
        #expect(try results["1.1.1.1"]?.get().isVpn == false, "the good address still answered")
    }

    @Test("a cache hit issues no second request")
    func cacheHitIssuesNoSecondRequest() async throws {
        let testCase = corpus.batchCase("cache-hit-issues-no-second-request")
        let stub = StubTransport.answering("1.1.1.1")
        let client = testClient(stub)

        for _ in 0..<(testCase.repeat ?? 1) {
            _ = try await client.lookupBatch(testCase.input)
        }
        await #expect(stub.callCount == testCase.expect.httpRequests)
    }

    @Test("two clients never share a cached answer")
    func twoClientsNeverShareACachedAnswer() async throws {
        let stub = StubTransport.answering("1.1.1.1")
        let a = testClient(stub, apiKey: "key-a")
        let b = testClient(stub, apiKey: "key-b")

        _ = try await a.lookup("1.1.1.1")
        _ = try await b.lookup("1.1.1.1")

        // Two keys can be on different plans and so entitled to different
        // fields; a shared cache would serve one of them the other's shape.
        await #expect(stub.callCount == 2)
    }

    @Test("the compiled-in bogon table matches the corpus")
    func bogonTableMatchesTheCorpus() {
        // Both are emitted by the same generator run, so a mismatch means one of
        // the two was regenerated without the other.
        #expect(Bogons.v4 == corpus.bogons.v4)
        #expect(Bogons.v6 == corpus.bogons.v6)
    }

    @Test("every generated bogon range parses")
    func bogonTableParses() {
        for cidr in Bogons.v4 {
            #expect(V4Range(cidr) != nil, "\(cidr) does not parse")
        }
        for cidr in Bogons.v6 {
            #expect(V6Range(cidr) != nil, "\(cidr) does not parse")
        }
        #expect(bogonRangesV4.count == Bogons.v4.count)
        #expect(bogonRangesV6.count == Bogons.v6.count)
    }

    @Test("every wire name the corpus asserts is a key of the served response")
    func corpusWireNamesAreRealKeys() {
        var names = Set(corpus.bogonResponse.flagsFalse + corpus.bogonResponse.emptyObjects)
        for testCase in corpus.lookup {
            names.formUnion(testCase.expect.present?.keys ?? [:].keys)
            names.formUnion(testCase.expect.absent ?? [])
            names.formUnion(testCase.expect.emptyPresent ?? [])
        }
        for name in names {
            #expect(Wire.isKnownKey(name), "\(name) is not a member of the served response")
            #expect(
                name == "is_vpn" || name == "ip" || Wire.flags[name] != nil
                    || Wire.details[name] != nil,
                "\(name) is served but nothing in the result exposes it",
            )
        }
    }
}

// The suite reads members by their WIRE name so it checks what the API actually
// serves; a rename inside the library cannot quietly satisfy an assertion.
extension ConformanceTests {
    func testClient(
        _ transport: StubTransport, apiKey: String? = nil, retries: Int = 2,
    ) -> VPNDetectionClient {
        VPNDetectionClient(
            options: .init(apiKey: apiKey, retries: retries, transport: transport),
        )
    }

    func expectFlag(_ result: LookupResult, _ wire: String, is want: Bool, _ label: String = "") {
        if wire == "is_vpn" {
            #expect(result.isVpn == want, "\(label): is_vpn")
            return
        }
        guard let reader = Wire.flags[wire] else {
            Issue.record("\(label): \(wire) is not a known flag")
            return
        }
        guard let got = reader(result) else {
            Issue.record("\(label): \(wire) must be present and \(want), but is absent")
            return
        }
        #expect(got == want, "\(label): \(wire)")
    }

    func expectAbsent(_ result: LookupResult, _ wire: String, _ label: String = "") {
        if let reader = Wire.flags[wire] {
            #expect(reader(result) == nil, "\(label): \(wire) must be ABSENT, not false")
            return
        }
        guard let reader = Wire.details[wire] else {
            Issue.record("\(label): \(wire) is neither a flag nor a detail object")
            return
        }
        #expect(reader(result) == nil, "\(label): \(wire) must be ABSENT, not empty")
    }

    func expectDetail(
        _ result: LookupResult, _ wire: String, is want: [String: JSONValue], _ label: String = "",
    ) {
        guard let reader = Wire.details[wire] else {
            Issue.record("\(label): \(wire) is not a known detail object")
            return
        }
        guard let got = reader(result) else {
            Issue.record("\(label): \(wire) must be present, but is absent")
            return
        }
        #expect(got == want, "\(label): \(wire)")
    }
}
