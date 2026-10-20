import Foundation
import Testing

@testable import VPNDetection

/// The shared conformance corpus that every VPNDetection SDK asserts.
///
/// Generated into `testdata/` and identical across languages, so a behavior that
/// drifts here fails here rather than surfacing as two client libraries quietly
/// disagreeing about the same address.
struct Corpus: Decodable, Sendable {
    let isBogon: [BogonCase]
    let ipv4Mapped: [MappedCase]
    let bogonResponse: BogonResponse
    let lookup: [LookupCase]
    let errors: [ErrorCase]
    let batch: [BatchCase]
    let bogons: BogonTable
    /// Read loosely, because its cases tell `null` apart from absent.
    let oauth: JSONValue

    struct BogonCase: Decodable, Sendable {
        let ip: String
        let expect: Bool
        let why: String
    }

    struct MappedCase: Decodable, Sendable {
        let ip: String
        let carries: String
        let expect: Bool
        let why: String
    }

    struct BogonResponse: Decodable, Sendable {
        let flagsFalse: [String]
        let emptyObjects: [String]
        let location: [String: JSONValue]
        let asn: [String: JSONValue]
    }

    struct LookupCase: Decodable, Sendable {
        let name: String
        let status: Int
        let body: JSONValue
        let expect: Expect

        struct Expect: Decodable, Sendable {
            let ip: String
            let isBogon: Bool
            let present: [String: Bool]?
            let absent: [String]?
            let emptyPresent: [String]?
            let vpn: [String: JSONValue]?
            let hosting: [String: JSONValue]?
            let dcproxy: [String: JSONValue]?
            let pubproxy: [String: JSONValue]?
            let location: [String: JSONValue]?
            let asn: [String: JSONValue]?
        }
    }

    struct ErrorCase: Decodable, Sendable {
        let name: String
        let status: Int
        let headers: [String: String]
        let body: JSONValue
        let expect: Expect

        struct Expect: Decodable, Sendable {
            let kind: String
            let retryable: Bool
            let message: String?
            let retryAfterSeconds: Int?
        }
    }

    struct BatchCase: Decodable, Sendable {
        let name: String
        let input: [String]
        let `repeat`: Int?
        let expect: Expect

        struct Expect: Decodable, Sendable {
            let keys: [String]?
            let httpRequests: Int?
            let bogonKeys: [String]?
            let errorKeys: [String]?
            let keyCount: Int?
            let errorKinds: [String: String]?
        }
    }

    struct BogonTable: Decodable, Sendable {
        let v4: [String]
        let v6: [String]
    }
}

extension Corpus {
    // Located from the source file rather than from a bundle: the corpus is
    // regenerated into the repository root, which is outside any
    // target directory and so cannot be declared as a SwiftPM resource.
    static let shared: Corpus = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let path = root.appendingPathComponent("testdata/testdata.json")
        guard let data = try? Data(contentsOf: path),
            let corpus = try? JSONDecoder().decode(Corpus.self, from: data)
        else {
            fatalError("could not read the conformance corpus at \(path.path)")
        }
        return corpus
    }()

    func batchCase(_ name: String) -> BatchCase {
        guard let found = batch.first(where: { $0.name == name }) else {
            fatalError("the corpus has no batch case named \(name)")
        }
        return found
    }
}

extension JSONValue {
    subscript(_ key: String) -> JSONValue? {
        guard case .object(let members) = self else {
            return nil
        }
        return members[key]
    }

    var arrayValue: [JSONValue] {
        guard case .array(let values) = self else {
            return []
        }
        return values
    }

    var objectValue: [String: JSONValue] {
        guard case .object(let members) = self else {
            return [:]
        }
        return members
    }

    /// The fixture body as the bytes a server would have sent.
    var encoded: Data {
        guard let data = try? JSONEncoder().encode(self) else {
            fatalError("a corpus fixture body could not be re-encoded")
        }
        return data
    }
}

// Members are addressed by their WIRE name throughout the corpus assertions, so
// the suite checks the names the API actually serves. `isKnownKey` proves each
// one really is a key of the generated response, which is what stops a typo in
// these tables from quietly satisfying an assertion.
enum Wire {
    static let flags: [String: @Sendable (LookupResult) -> Bool?] = [
        "is_hosting": { $0.isHosting },
        "is_relay": { $0.isRelay },
        "is_tor": { $0.isTor },
        "is_cdn": { $0.isCdn },
        "is_resproxy": { $0.isResproxy },
        "is_dcproxy": { $0.isDcproxy },
        "is_mobproxy": { $0.isMobproxy },
        "is_pubproxy": { $0.isPubproxy },
    ]

    static let details: [String: @Sendable (LookupResult) -> [String: JSONValue]?] = [
        "vpn": { $0.vpn?.wireFields },
        "hosting": { $0.hosting?.wireFields },
        "relay": { $0.relay?.wireFields },
        "tor": { $0.tor?.wireFields },
        "cdn": { $0.cdn?.wireFields },
        "resproxy": { $0.resproxy?.wireFields },
        "dcproxy": { $0.dcproxy?.wireFields },
        "mobproxy": { $0.mobproxy?.wireFields },
        "pubproxy": { $0.pubproxy?.wireFields },
        "location": { $0.location?.wireFields },
        "asn": { $0.asn?.wireFields },
    ]

    static func isKnownKey(_ wire: String) -> Bool {
        Components.Schemas.LookupResponse.CodingKeys(rawValue: wire) != nil
    }
}

extension VpnDetail {
    var wireFields: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        provider.map { fields["provider"] = .string($0) }
        lastSeen.map { fields["last_seen"] = .string($0) }
        confidence.map { fields["confidence"] = .string($0) }
        method.map { fields["method"] = .string($0) }
        return fields
    }
}

extension ClassDetail {
    var wireFields: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        provider.map { fields["provider"] = .string($0) }
        confidence.map { fields["confidence"] = .string($0) }
        lastSeen.map { fields["last_seen"] = .string($0) }
        return fields
    }
}

extension ProxyDetail {
    var wireFields: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        provider.map { fields["provider"] = .string($0) }
        firstSeen.map { fields["first_seen"] = .string($0) }
        lastSeen.map { fields["last_seen"] = .string($0) }
        hits.map { fields["hits"] = .int($0) }
        hitsDaysPct.map { fields["hits_days_pct"] = .int($0) }
        providersNum.map { fields["providers_num"] = .int($0) }
        return fields
    }
}

extension PubproxyDetail {
    var wireFields: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        entry.map { fields["entry"] = .bool($0) }
        exit.map { fields["exit"] = .bool($0) }
        protocols.map { fields["protocols"] = .array($0.map { .string($0) }) }
        numPorts.map { fields["num_ports"] = .int($0) }
        numProxies.map { fields["num_proxies"] = .int($0) }
        lastSeen.map { fields["last_seen"] = .string($0) }
        lastUsable.map { fields["last_usable"] = .string($0) }
        return fields
    }
}

extension Location {
    var wireFields: [String: JSONValue] {
        [
            "continent": .string(continent), "continent_name": .string(continentName),
            "country": .string(country), "country_name": .string(countryName),
            "timezone": .string(timezone), "currency_code": .string(currencyCode),
            "currency_name": .string(currencyName), "currency_symbol": .string(currencySymbol),
            "flag_emoji": .string(flagEmoji), "flag_unicode": .string(flagUnicode),
        ]
    }
}

extension Asn {
    var wireFields: [String: JSONValue] {
        [
            "asn": .int(asn), "name": .string(name), "domain": .string(domain),
            "type": .string(type), "prefix": .string(prefix),
        ]
    }
}
