import Foundation
import Testing

@testable import VPNDetection

// Through 4.10.1 each of these came back as an answer: a `date-time` as Linux's
// ISO 8601 transcoders guessed it (30 February as 2 March, `24:00` as the next
// day, `+0500` as a zone), a `date` as served whatever it held, and a
// `license_type` of `""` as no license at all.
@Suite("Dates and closed values in an answer")
struct AnswerDateTests {
    static let badDateTimes = [
        "x", "tomorrow", "2026-02-30T00:00:00Z", "2026-11-31T00:00:00Z", "2026-10-05T24:00:00Z",
        "2026-10-05T07:49:45", "2026-10-05", "2026-10-05T07:49Z", "2026-10-05T07:49:45+0500",
        "2026-10-05T07:49:45+05", "2026-10-05T07:49:45+24:00", "2026-10-05T07:49:45+05:60",
        "2026-10-05T07:49:45UTC", " 2026-10-05T07:49:45Z", "2026-10-5T07:49:45Z",
    ]

    static let badDates = [
        "", "x", "tomorrow", "monday", "2026-02-30", "2026-11-31", "2026-10-5", "2026-10-05T00:00:00Z",
        "20261005", "2026-W41-1", " 2026-10-05",
    ]

    @Test("a date-time the spec does not allow is a retried server error")
    func aBadDateTimeIsRetried() async throws {
        for value in Self.badDateTimes {
            var family = Self.family
            family["starts"] = value
            var download = Self.download
            download["created"] = value
            var usage = Self.entitlement
            usage["usage"] = (Self.entitlement["usage"] as? [String: Any] ?? [:]).merging(["window_end": value]) { $1 }
            let cases: [(String, [String: Any], @Sendable (VPNDetectionClient) async throws -> Void)] = [
                ("/api/v1/database/list", ["databases": [family]], { _ = try await $0.database.list() }),
                ("/api/v1/database/downloads", ["downloads": [download]], { _ = try await $0.database.downloads() }),
                ("/api/v1/entitlement", usage, { _ = try await $0.myEntitlement() }),
            ]
            for (path, body, call) in cases {
                try await expectRetried(path, body, value, call)
            }
        }
    }

    @Test("a date the spec does not allow is a retried server error")
    func aBadDateIsRetried() async throws {
        for value in Self.badDates {
            let metadata: [String: Any] = [
                "id": "vpn_ip_v1", "updated": value, "entries": 44, "schema": ["csvgz": [Any]()],
            ]
            let lookup: [String: Any] = ["ip": "45.83.91.1", "is_vpn": true, "vpn": ["last_seen": value]]
            let proxy: [String: Any] = ["ip": "45.83.91.1", "is_vpn": false, "resproxy": ["first_seen": value]]
            let cases: [(String, [String: Any], @Sendable (VPNDetectionClient) async throws -> Void)] = [
                ("/api/v1/database/metadata", metadata, { _ = try await $0.database.metadata(id: "vpn_ip_v1") }),
                ("45.83.91.1", lookup, { _ = try await $0.lookup("45.83.91.1") }),
                ("45.83.91.1", proxy, { _ = try await $0.lookup("45.83.91.1") }),
                ("myip", lookup, { _ = try await $0.myIP() }),
            ]
            for (path, body, call) in cases {
                try await expectRetried(path, body, value, call)
            }
        }
    }

    // A batch entry it cannot read is that address's error alone, sent once.
    @Test("a batch entry holding a bad date fails that address alone")
    func aBadDateInABatchEntryFailsThatAddress() async throws {
        for value in Self.badDates {
            let stub = StubTransport([
                "45.83.91.1": .json(["ip": "45.83.91.1", "is_vpn": true, "hosting": ["last_seen": value]]),
                "45.83.91.2": .json(["ip": "45.83.91.2", "is_vpn": true, "vpn": ["last_seen": "2026-10-05"]]),
            ])
            let results = try await client(stub, retries: 1).lookupBatch(["45.83.91.1", "45.83.91.2"])
            guard case .failure(let error) = results["45.83.91.1"] else {
                Issue.record("\(value.debugDescription) came back as an answer")
                continue
            }
            #expect(error.kind == .serverError, "\(value.debugDescription)")
            #expect(error.status == 200, "\(value.debugDescription)")
            guard case .success(let served) = results["45.83.91.2"] else {
                Issue.record("the good entry beside \(value.debugDescription) failed")
                continue
            }
            #expect(served.vpn?.lastSeen == "2026-10-05")
            await #expect(stub.callCount == 1, "\(value.debugDescription)")
        }
    }

    @Test("a license type of \"\" is a retried server error, and null is no license")
    func anEmptyLicenseTypeIsRetried() async throws {
        var family = Self.family
        family["license_type"] = ""
        try await expectRetried("/api/v1/database/list", ["databases": [family]], "\"\"") {
            _ = try await $0.database.list()
        }
        family["license_type"] = NSNull()
        let stub = StubTransport(["/api/v1/database/list": .json(["databases": [family]])])
        let databases = try await client(stub).database.list()
        #expect(databases.count == 1)
        #expect(databases.first?.licenseType == nil)
    }

    @Test("every RFC 3339 form is read, a lowercase t and z and an offset included")
    func everyRfc3339FormIsRead() async throws {
        let forms: [(String, Double)] = [
            ("2026-10-05T07:49:45Z", 1_791_186_585),
            ("2026-10-05t07:49:45z", 1_791_186_585),
            ("2026-10-05T07:49:45.118Z", 1_791_186_585.118),
            ("2026-10-05T07:49:45+05:00", 1_791_168_585),
            ("2026-10-05T07:49:45-03:30", 1_791_199_185),
        ]
        for (value, epoch) in forms {
            var family = Self.family
            family["starts"] = value
            let stub = StubTransport(["/api/v1/database/list": .json(["databases": [family]])])
            let databases = try await client(stub).database.list()
            let starts = try #require(databases.first?.starts, "\(value)")
            #expect(abs(starts.timeIntervalSince1970 - epoch) < 1e-3, "\(value)")
        }
        let metadata: [String: Any] = [
            "id": "vpn_ip_v1", "updated": "2024-02-29", "entries": 44, "schema": ["csvgz": [Any]()],
        ]
        let stub = StubTransport(["/api/v1/database/metadata": .json(metadata)])
        #expect(try await client(stub).database.metadata(id: "vpn_ip_v1").updated == "2024-02-29")
    }

    @Test("a date-time is RFC 3339 and nothing else")
    func aDateTimeIsRfc3339Alone() throws {
        func at(_ text: String) -> Double? { RFC3339.dateTime(text)?.timeIntervalSince1970 }
        #expect(at("2026-10-05T07:49:45Z") == 1_791_186_585)
        #expect(at("2026-10-05t07:49:45z") == 1_791_186_585)
        #expect(at("2026-10-05T07:49:45-00:00") == 1_791_186_585)
        #expect(at("2026-10-05T07:49:45+05:00") == 1_791_168_585)
        #expect(at("2026-10-05T07:49:45-03:30") == 1_791_199_185)
        #expect(at("2024-02-29T00:00:00Z") == 1_709_164_800)
        #expect(at("0000-01-01T00:00:00Z") == -62_167_219_200)
        #expect(abs(try #require(at("2026-10-05T07:49:45.118Z")) - 1_791_186_585.118) < 1e-6)
        #expect(abs(try #require(at("2026-10-05T07:49:45.123456789+01:00")) - 1_791_182_985.123_456_789) < 1e-6)
        for value in Self.badDateTimes + [
            "", "1700000000", "1.5", "2025-02-29T00:00:00Z", "2026-13-05T07:49:45Z", "2026-00-05T07:49:45Z",
            "2026-10-00T07:49:45Z", "2026-10-05T07:60:00Z", "2026-12-31T23:59:60Z", "2026-10-05T07:49:45Z ",
            "2026-10-05 07:49:45Z", "2026-10-05T07:49:45.Z", "2026-10-05T07:49:45,5Z", "2026-10-05T07:49:45+05:00:30",
            "2026-10-05T07:49:45 PST", "2026-10-05T07:49:45ZZ", "2026-10-05T07:49:45+05:00Z", "2026-W41-1T07:49:45Z",
            "2026-278T07:49:45Z", "20261005T074945Z", "+20261-10-05T07:49:45Z", "\u{FF12}026-10-05T07:49:45Z",
        ] {
            #expect(at(value) == nil, "\(value.debugDescription) is no date-time")
        }
    }

    @Test("a full-date is YYYY-MM-DD on a day that exists")
    func aFullDateIsADayThatExists() {
        for value in ["2026-10-05", "2024-02-29", "0000-01-01"] {
            #expect(RFC3339.isFullDate(value), "\(value.debugDescription) is a date")
        }
        for value in Self.badDates + [
            "2025-02-29", "2026-13-05", "2026-00-05", "2026-10-00", "2026-278", "2026-10-05 ", "+2026-10-05",
            "20261-10-05",
        ] {
            #expect(!RFC3339.isFullDate(value), "\(value.debugDescription) is no date")
        }
    }

    private func expectRetried(
        _ path: String, _ body: [String: Any], _ value: String,
        _ call: @Sendable (VPNDetectionClient) async throws -> Void,
    ) async throws {
        let stub = StubTransport([path: .json(body)])
        let failure = await #expect(throws: VPNDetectionError.self, "\(path) \(value.debugDescription)") {
            try await call(client(stub, retries: 1))
        }
        guard let failure else {
            return
        }
        #expect(failure.kind == .serverError, "\(path) \(value.debugDescription)")
        #expect(failure.status == 200, "\(path) \(value.debugDescription)")
        await #expect(stub.callCount == 2, "\(path) \(value.debugDescription)")
    }

    private func client(_ stub: StubTransport, retries: Int = 2) -> VPNDetectionClient {
        VPNDetectionClient(options: .init(apiKey: "key", cache: nil, retries: retries, transport: stub))
    }

    nonisolated(unsafe) static let family: [String: Any] = [
        "base": "vpn_ip",
        "name": "vpn_ip",
        "summary": "vpn_ip rows",
        "license_type": "standard",
        "in_term": true,
        "standing": "licensed",
        "open": false,
        "starts": "2026-09-04T18:04:26.431Z",
        "versions": [["id": "vpn_ip_v1", "version": 1, "formats": [Any]()]],
    ]

    nonisolated(unsafe) static let download: [String: Any] = [
        "dataset_id": "vpn_ip_v1", "format": "csvgz", "outcome": "ok", "sample": false, "open": false,
        "bytes": 264, "http_status": 302, "apikey_id": NSNull(), "client_ip": NSNull(), "user_agent": NSNull(),
        "created": "2026-10-05T07:49:45.118Z",
    ]

    nonisolated(unsafe) static let entitlement: [String: Any] = ClientTests.entitlementBody
}
