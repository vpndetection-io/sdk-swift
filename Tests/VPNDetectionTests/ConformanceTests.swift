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

    // A server listening on :: sees every IPv4 visitor as ::ffff:a.b.c.d. Read
    // whole that is inside ::ffff:0:0/96, so an SDK that did not unmap answered
    // each one locally as a bogon.
    @Test("an IPv4-mapped address is the IPv4 address it carries")
    func ipv4MappedAddressIsTheAddressItCarries() async throws {
        for testCase in corpus.ipv4Mapped {
            let label = "\(testCase.ip) (\(testCase.why))"
            #expect(VPNDetection.isBogon(testCase.ip) == testCase.expect, "\(label): isBogon")

            let stub = StubTransport.answering(testCase.carries)
            let client = testClient(stub, retries: 0)
            let result = try await client.lookup(testCase.ip)
            #expect(result.ip == testCase.carries, "\(label): the answer names the address it carries")
            #expect(result.isBogon == testCase.expect, "\(label): answered locally exactly when a bogon")
            if testCase.expect {
                await #expect(stub.callCount == 0, "\(label): a bogon must not reach the network")
            } else {
                await #expect(stub.calls == [testCase.carries], "\(label): sent as \(testCase.carries)")
                _ = try await client.lookup(testCase.carries)
                await #expect(stub.callCount == 1, "\(label): \(testCase.carries) is then a cache hit")
            }

            // The mapped form alone: asked beside its plain form, a batch that sent
            // the address as given would still have been answered for the plain one.
            let batchStub = StubTransport.answering(testCase.carries)
            let results = try await testClient(batchStub, retries: 0).lookupBatch([testCase.ip])
            #expect(results.keys == [testCase.ip], "\(label): keyed as passed")
            #expect(try results[testCase.ip]?.get().ip == testCase.carries, "\(label): batch answer")
            let sent = await batchStub.batchIps
            #expect(sent == (testCase.expect ? [] : [testCase.carries]), "\(label): the batch body")
        }
    }

    @Test("a bogon is answered locally in the widest shape")
    func bogonIsAnsweredLocallyInTheWidestShape() async throws {
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
        expectDetail(result, "location", is: corpus.bogonResponse.location)
        expectDetail(result, "asn", is: corpus.bogonResponse.asn)
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
            testCase.expect.pubproxy.map { expectDetail(result, "pubproxy", is: $0, testCase.name) }
            testCase.expect.location.map { expectDetail(result, "location", is: $0, testCase.name) }
            testCase.expect.asn.map { expectDetail(result, "asn", is: $0, testCase.name) }
        }
    }

    @Test("a 429 is classified by Retry-After, not by its status")
    func errorsAreClassifiedByRange() async throws {
        for testCase in corpus.errors {
            let route = StubTransport.Route(
                status: testCase.status, body: testCase.body.encoded, headers: testCase.headers,
            )
            // A non-retryable case is sent with retries ON, so the request count
            // below is what says it was not retried: with retries off one request
            // is guaranteed, and a classifier that retried every failure passed
            // this test unchanged. A retryable case keeps them off so it surfaces
            // here rather than looping; retriesAreConfigurablePerCall and
            // rateLimitWaitsForRetryAfter are what assert that one does retry.
            let stub = StubTransport(["1.1.1.1": route])
            let client = testClient(stub, retries: testCase.expect.retryable ? 0 : 2)

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
            #expect(await stub.callCount == 1, "\(testCase.name): requests")
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
            guard case .failure(let error) = results[ip] else {
                Issue.record("\(ip) should carry its own error")
                continue
            }
            #expect(error.kind.rawValue == testCase.expect.errorKinds?[ip], "\(ip)")
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

    // The second case pins that no cap refuses a batch past the endpoint's thousand.
    @Test(
        "a large batch is sent in chunks of a thousand",
        arguments: ["chunks-of-one-thousand", "uncapped-input-is-chunked"],
    )
    func largeBatchIsSentInChunksOfAThousand(_ name: String) async throws {
        let testCase = corpus.batchCase(name)
        let stub = StubTransport(StubTransport.answers(for: testCase.input))
        let client = VPNDetectionClient(options: .init(cache: nil, transport: stub))

        let results = try await client.lookupBatch(testCase.input)

        #expect(results.count == testCase.expect.keyCount)
        await #expect(stub.callCount == testCase.expect.httpRequests)
        for ip in testCase.input {
            #expect(try results[ip]?.get().ip == ip, "\(ip) should be answered for itself")
        }
    }

    // A per-entry failure carries no headers, so its 429 can only be a spent
    // allowance, and a 500 is the server's; neither is retried per entry, because
    // retries belong to the call and the call succeeded.
    @Test("an entry error is classified by its status")
    func entryErrorIsClassifiedByItsStatus() async throws {
        let testCase = corpus.batchCase("an-entry-error-is-classified-by-its-status")
        var routes = StubTransport.answers(for: ["1.1.1.1"])
        routes["8.8.8.8"] = .json(
            ["error": "overage cap reached; raise or remove it in Billing"], status: 429,
        )
        routes["9.9.9.9"] = .json(["error": "lookup failed"], status: 500)
        let stub = StubTransport(routes)
        let client = testClient(stub, retries: 3)

        let results = try await client.lookupBatch(testCase.input)

        #expect(results.keys == testCase.expect.keys)
        for (ip, kind) in testCase.expect.errorKinds ?? [:] {
            guard case .failure(let error) = results[ip] else {
                Issue.record("\(ip) should carry its error")
                continue
            }
            #expect(error.kind.rawValue == kind, "\(ip)")
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

    // Each vocabulary case serves a value no published list holds, or the plan's
    // name, and reads it back through the typed result by its wire path. A path
    // the result does not surface reads as absent, so a case the corpus adds stays
    // red until this SDK reads it.
    @Test("every vocabulary case reads as served", arguments: Corpus.shared.vocabulary.cases.map(\.name))
    func vocabularyReadsAsServed(_ name: String) async throws {
        let testCase = corpus.vocabularyCase(name)
        let paths = [
            "myEntitlement": "/api/v1/entitlement",
            "listDatabases": "/api/v1/database/list",
            "listDownloads": "/api/v1/database/downloads",
        ]
        let path = try #require(paths[testCase.call], "\(name): no call \(testCase.call)")
        let stub = StubTransport([path: .init(status: 200, body: testCase.answer.encoded)])
        let client = testClient(stub, retries: 0)

        let read: JSONValue =
            switch testCase.call {
            case "myEntitlement": try await Self.tree(client.myEntitlement())
            case "listDatabases": try await Self.tree(client.database.list())
            default: try await Self.tree(client.database.downloads())
            }

        #expect(!testCase.expect.isEmpty, "\(name) asserts nothing")
        for (key, want) in testCase.expect {
            #expect(read.at(key) == want, "\(name): \(key)")
        }
    }

    // A wrong type, an empty value or a null where the member is required is
    // still an answer the call cannot read; only a null license type, no license
    // at all, reads.
    @Test(
        "a vocabulary member of the wrong type is refused",
        arguments: [
            ("entitlement-tier-unknown", "plan.tier"),
            ("database-standing-unknown", "databases.0.standing"),
            ("database-license-type-unknown", "databases.0.license_type"),
            ("database-format-unknown", "databases.0.versions.0.formats.0.format"),
            ("database-format-unknown", "databases.0.versions.0.sample_formats.0"),
            ("download-outcome-unknown", "downloads.0.outcome"),
        ],
    )
    func vocabularyWrongTypeIsRefused(_ name: String, _ member: String) async throws {
        let testCase = corpus.vocabularyCase(name)
        let paths = [
            "myEntitlement": "/api/v1/entitlement",
            "listDatabases": "/api/v1/database/list",
            "listDownloads": "/api/v1/database/downloads",
        ]
        let path = try #require(paths[testCase.call])
        let nullable = member.hasSuffix("license_type")
        for served: JSONValue in [.int(1), .string(""), .bool(true), .object([:]), .null] {
            let body = testCase.answer.setting(member, to: served).encoded
            let stub = StubTransport([path: .init(status: 200, body: body)])
            let client = testClient(stub, retries: 0)
            do {
                let read: JSONValue =
                    switch testCase.call {
                    case "myEntitlement": try await Self.tree(client.myEntitlement())
                    case "listDatabases": try await Self.tree(client.database.list())
                    default: try await Self.tree(client.database.downloads())
                    }
                #expect(served == .null && nullable, "\(name): \(member) as \(served) was read")
                #expect(read.at(member) == .null, "\(name): \(member)")
            } catch let error as VPNDetectionError {
                #expect(!(served == .null && nullable), "\(name): a null \(member) was refused")
                #expect(error.kind == .serverError, "\(name): \(member) as \(served)")
            }
        }
    }

    @Test("a value outside a list compares by what was served")
    func vocabularyComparesByValue() {
        #expect(Database.Standing(rawValue: "licensed") == .licensed)
        #expect(Database.Standing.licensed.isKnown)
        #expect(!Database.Standing(rawValue: "suspended").isKnown)
        #expect(Database.Standing(rawValue: "suspended") == Database.Standing(rawValue: "suspended"))
        #expect(Database.Standing(rawValue: "suspended") != .licensed)
        #expect(Entitlement.Plan.Tier.known.map(\.rawValue) == ["free", "starter", "scale", "max"])
        #expect("\(Download.Outcome(rawValue: "throttled"))" == "throttled")
    }

    @Test("a format outside the published list is refused before the network")
    func unpublishedFormatIsRefused() async {
        let stub = StubTransport()
        let client = testClient(stub)
        let parquet = DatabaseFormat(rawValue: "parquet")
        let calls: [(String, () async throws -> Void)] = [
            ("checksums", { _ = try await client.database.checksums(id: "vpn_ip_v1", format: parquet) }),
            ("downloadURL", { _ = try await client.database.downloadURL(id: "vpn_ip_v1", format: parquet) }),
            ("downloadBytes", { _ = try await client.database.downloadBytes("vpn_ip_v1", format: parquet) }),
        ]
        for (name, call) in calls {
            do {
                try await call()
                Issue.record("\(name) sent a format no list holds")
            } catch let error as VPNDetectionError {
                #expect(error.kind == .badRequest, "\(name)")
            } catch {
                Issue.record("\(name): \(error)")
            }
        }
        #expect(await stub.callCount == 0)
    }

    // Each typed result as the wire paths the vocabulary cases name.
    static func tree(_ ent: Entitlement) -> JSONValue {
        .object([
            "plan": .object([
                "key": .string(ent.plan.key),
                "name": .string(ent.plan.name),
                "tier": .string(ent.plan.tier.rawValue),
            ]),
        ])
    }

    static func tree(_ databases: [Database]) -> JSONValue {
        .object([
            "databases": .array(databases.map { database in
                .object([
                    "base": .string(database.base),
                    "standing": .string(database.standing.rawValue),
                    "license_type": database.licenseType.map { .string($0.rawValue) } ?? .null,
                    "versions": .array(database.versions.map { version in
                        .object([
                            "id": .string(version.id),
                            "formats": .array(version.formats.map { size in
                                .object([
                                    "format": .string(size.format.rawValue),
                                    "bytes": size.bytes.map { .int(Int($0)) } ?? .null,
                                ])
                            }),
                            "sample_formats": .array(version.sampleFormats.map { .string($0.rawValue) }),
                        ])
                    }),
                ])
            }),
        ])
    }

    static func tree(_ downloads: [Download]) -> JSONValue {
        .object([
            "downloads": .array(downloads.map { download in
                .object([
                    "dataset_id": .string(download.datasetId),
                    "format": .string(download.format),
                    "outcome": .string(download.outcome.rawValue),
                ])
            }),
        ])
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
