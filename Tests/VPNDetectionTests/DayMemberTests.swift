import Foundation
import Testing

@testable import VPNDetection

// The first and last days of the SSH, mail, web, resolver, BitTorrent and bot
// details are `format: date` from spec 2026.11.23. Through 5.2.0 each came back
// as served, whatever it held.
@Suite("The day members of a detail")
struct DayMemberTests {
    static let address = "45.83.91.1"

    // Every detail holding a day, populated, each day a different one so a member
    // read from the wrong key cannot pass.
    nonisolated(unsafe) static let answer: [String: Any] = [
        "ip": address, "is_vpn": false, "is_ssh": true, "is_smtp": true, "is_web": true,
        "is_dns_resolver": true, "is_bittorrent": true, "is_bot": true,
        "ssh": [
            "port": 22, "banner": "SSH-2.0-OpenSSH_9.6", "host_key_fp": "SHA256:x", "session_ok": true,
            "first_seen": "2026-08-01", "last_seen": "2026-11-01",
        ],
        "smtp": [
            "port": 25, "banner": "220 mail ESMTP", "session_ok": false,
            "first_seen": "2026-08-02", "last_seen": "2026-11-02",
        ],
        "web": [[
            "port": 443, "tls_ok": true, "session_ok": true, "status_code": 200, "server": "nginx",
            "location": "", "title": "Welcome", "cert_subject_cn": "example.com", "cert_subject_o": "",
            "cert_issuer_dn": "CN=R11", "cert_browser_trusted": true, "tls_version": "TLSv1.3",
            "first_seen": "2026-08-03", "last_seen": "2026-11-03",
        ]],
        "dns_resolver": [
            "port": 53, "recursion_available": true, "rcode": 0, "answer_correct": true,
            "first_seen": "2026-08-04", "last_seen": "2026-11-04",
        ],
        "bittorrent": [
            "verified": true, "id_matches_ip": false, "first_seen": "2024-02-29", "last_seen": "2026-11-05",
            "last_reachable": "", "days_seen": 3, "num_ports": 1, "peak_num_ports": 1, "indexer": false,
            "clients": ["qB"],
        ],
        "bot": [
            "provider": "google", "provider_name": "Google", "agents": ["Googlebot"],
            "categories": ["search_engine"], "verified": true, "identity": "verified", "verified_by": "list",
            "confidence": "high", "first_seen": "2026-08-06", "last_seen": "2026-11-06",
        ],
    ]

    // Each of the twelve, by detail and member.
    static let members: [(String, String)] = [
        ("ssh", "first_seen"), ("ssh", "last_seen"), ("smtp", "first_seen"), ("smtp", "last_seen"),
        ("web", "first_seen"), ("web", "last_seen"), ("dns_resolver", "first_seen"),
        ("dns_resolver", "last_seen"), ("bittorrent", "first_seen"), ("bittorrent", "last_seen"),
        ("bot", "first_seen"), ("bot", "last_seen"),
    ]

    // The date probe: words a date parser reads, days that do not exist, a time
    // where none belongs, an offset, a final newline and another script's digits.
    static let probe = [
        "x", "tomorrow", "monday", "2026-02-30", "2026-11-31", "2026-11-05T24:00", "2026-11-05T00:00:00Z",
        "2026-11-05 00:00", "2026-11-05+05", "2026-11-05+05:00", "2026-11-05\n", " 2026-11-05",
        "2026-11-5", "20261105", "\u{0662}026-11-05", "\u{FF12}026-11-05", "",
    ]

    @Test("every day member of a well-formed answer is read as served")
    func aWellFormedAnswerIsRead() async throws {
        let stub = StubTransport([Self.address: .json(Self.answer)])
        let result = try await client(stub).lookup(Self.address)
        #expect(result.ssh?.firstSeen == "2026-08-01")
        #expect(result.ssh?.lastSeen == "2026-11-01")
        #expect(result.smtp?.firstSeen == "2026-08-02")
        #expect(result.smtp?.lastSeen == "2026-11-02")
        #expect(result.web?.first?.firstSeen == "2026-08-03")
        #expect(result.web?.first?.lastSeen == "2026-11-03")
        #expect(result.dnsResolver?.firstSeen == "2026-08-04")
        #expect(result.dnsResolver?.lastSeen == "2026-11-04")
        #expect(result.bittorrent?.firstSeen == "2024-02-29")
        #expect(result.bittorrent?.lastSeen == "2026-11-05")
        #expect(result.bittorrent?.lastReachable == "", "last_reachable is no date and stays as served")
        #expect(result.bot?.firstSeen == "2026-08-06")
        #expect(result.bot?.lastSeen == "2026-11-06")
        await #expect(stub.callCount == 1)
    }

    @Test("a day the spec does not allow is a retried server error")
    func theProbeIsRefused() async throws {
        // The same harness reads the answer whole first, so a refusal below is the
        // value's and not the fixture's.
        _ = try await client(StubTransport([Self.address: .json(Self.answer)])).lookup(Self.address)
        for value in Self.probe {
            try await expectRetried(Self.with("bot", "last_seen", value), "bot.last_seen \(value.debugDescription)")
        }
    }

    @Test("each of the twelve refuses a value that is no day")
    func eachMemberRefusesAWord() async throws {
        for (detail, member) in Self.members {
            try await expectRetried(Self.with(detail, member, "x"), "\(detail).\(member)")
        }
    }

    @Test("a batch entry holding a bad day fails that address alone")
    func aBatchEntryFailsAlone() async throws {
        for (detail, member) in Self.members {
            var good = Self.answer
            good["ip"] = "45.83.91.2"
            let stub = StubTransport([
                Self.address: .json(Self.with(detail, member, "tomorrow")),
                "45.83.91.2": .json(good),
            ])
            let results = try await client(stub, retries: 1).lookupBatch([Self.address, "45.83.91.2"])
            guard case .failure(let error) = results[Self.address] else {
                Issue.record("\(detail).\(member) tomorrow came back as an answer")
                continue
            }
            #expect(error.kind == .serverError, "\(detail).\(member)")
            #expect(error.status == 200, "\(detail).\(member)")
            guard case .success(let served) = results["45.83.91.2"] else {
                Issue.record("the good entry beside \(detail).\(member) failed")
                continue
            }
            #expect(served.bot?.lastSeen == "2026-11-06")
            await #expect(stub.callCount == 1, "\(detail).\(member)")
        }
    }

    // The answer with one member of one detail replaced.
    static func with(_ detail: String, _ member: String, _ value: String) -> [String: Any] {
        var body = answer
        if detail == "web" {
            var rows = body["web"] as? [[String: Any]] ?? []
            rows[0][member] = value
            body["web"] = rows
        } else {
            var object = body[detail] as? [String: Any] ?? [:]
            object[member] = value
            body[detail] = object
        }
        return body
    }

    private func expectRetried(_ body: [String: Any], _ label: String) async throws {
        let stub = StubTransport([Self.address: .json(body)])
        let failure = await #expect(throws: VPNDetectionError.self, "\(label)") {
            _ = try await client(stub, retries: 1).lookup(Self.address)
        }
        guard let failure else {
            return
        }
        #expect(failure.kind == .serverError, "\(label)")
        #expect(failure.status == 200, "\(label)")
        await #expect(stub.callCount == 2, "\(label)")
    }

    private func client(_ stub: StubTransport, retries: Int = 2) -> VPNDetectionClient {
        VPNDetectionClient(options: .init(apiKey: "key", cache: nil, retries: retries, transport: stub))
    }
}
