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
    let vocabulary: Vocabulary

    /// Values the API may add to a closed list, and the plan's name. Each
    /// `expect` key is a wire path through the answer.
    struct Vocabulary: Decodable, Sendable {
        let cases: [Case]

        struct Case: Decodable, Sendable {
            let name: String
            let call: String
            let answer: JSONValue
            let expect: [String: JSONValue]
        }
    }

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

    /// The bogon answer's two lists, and in `members` every other key the corpus
    /// gives it (location, asn, web, hostname, company, abuse and whatever it
    /// gains), each a wire member the answer must hold as written.
    struct BogonResponse: Decodable, Sendable {
        let flagsFalse: [String]
        let emptyObjects: [String]
        let members: [String: JSONValue]

        init(from decoder: any Decoder) throws {
            var all = try JSONValue(from: decoder).objectValue
            flagsFalse = (all.removeValue(forKey: "flagsFalse")?.arrayValue ?? []).compactMap(\.stringValue)
            emptyObjects = (all.removeValue(forKey: "emptyObjects")?.arrayValue ?? [])
                .compactMap(\.stringValue)
            all.removeValue(forKey: "why")
            members = all
        }
    }

    struct LookupCase: Decodable, Sendable {
        let name: String
        let status: Int
        let body: JSONValue
        let expect: Expect

        /// The keys naming a role, and in `members` every other key, each a wire
        /// member the answer must hold as written. Reading them all, rather than
        /// a list of the ones known when this was written, is what keeps a member
        /// the corpus gains from passing unasserted: one the suite has no reader
        /// for fails in `expectMember`.
        struct Expect: Decodable, Sendable {
            let ip: String
            let isBogon: Bool
            let present: [String: Bool]?
            let absent: [String]?
            let emptyPresent: [String]?
            let members: [String: JSONValue]

            private enum Role: String, CodingKey, CaseIterable {
                case ip, isBogon, present, absent, emptyPresent
            }

            init(from decoder: any Decoder) throws {
                let roles = try decoder.container(keyedBy: Role.self)
                ip = try roles.decode(String.self, forKey: .ip)
                isBogon = try roles.decode(Bool.self, forKey: .isBogon)
                present = try roles.decodeIfPresent([String: Bool].self, forKey: .present)
                absent = try roles.decodeIfPresent([String].self, forKey: .absent)
                emptyPresent = try roles.decodeIfPresent([String].self, forKey: .emptyPresent)
                var all = try JSONValue(from: decoder).objectValue
                for role in Role.allCases {
                    all.removeValue(forKey: role.rawValue)
                }
                members = all
            }
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

    func vocabularyCase(_ name: String) -> Vocabulary.Case {
        guard let found = vocabulary.cases.first(where: { $0.name == name }) else {
            fatalError("the corpus has no vocabulary case named \(name)")
        }
        return found
    }

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

    /// The value at a dotted wire path, a number indexing a list, or nil.
    func at(_ path: String) -> JSONValue? {
        var node: JSONValue? = self
        for step in path.split(separator: ".") {
            switch node {
            case .object(let members): node = members[String(step)]
            case .array(let items):
                guard let index = Int(step), items.indices.contains(index) else {
                    return nil
                }
                node = items[index]
            default: return nil
            }
        }
        return node
    }

    /// A copy with the value at a dotted wire path replaced.
    func setting(_ path: String, to value: JSONValue) -> JSONValue {
        var steps = path.split(separator: ".").map(String.init)
        guard !steps.isEmpty else {
            return value
        }
        let step = steps.removeFirst()
        let rest = steps.joined(separator: ".")
        switch self {
        case .object(var members):
            members[step] = (members[step] ?? .null).setting(rest, to: value)
            return .object(members)
        case .array(var items):
            guard let index = Int(step), items.indices.contains(index) else {
                return self
            }
            items[index] = items[index].setting(rest, to: value)
            return .array(items)
        default:
            return self
        }
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
        "is_anycast": { $0.isAnycast },
        "is_carrier": { $0.isCarrier },
        "is_satellite": { $0.isSatellite },
        "is_ssh": { $0.isSsh },
        "is_smtp": { $0.isSmtp },
        "is_web": { $0.isWeb },
        "is_dns_resolver": { $0.isDnsResolver },
        "is_bittorrent": { $0.isBittorrent },
        "trial_expired": { $0.trialExpired },
        "cap_reached": { $0.capReached },
    ]

    /// Every member that is not a flag, as the JSON it was served as: a detail
    /// or shared object as an object of its present keys, `web` as a list of
    /// them, `hostname` as a string.
    static let members: [String: @Sendable (LookupResult) -> JSONValue?] = [
        "vpn": { $0.vpn.map { .object($0.wireFields) } },
        "hosting": { $0.hosting.map { .object($0.wireFields) } },
        "relay": { $0.relay.map { .object($0.wireFields) } },
        "tor": { $0.tor.map { .object($0.wireFields) } },
        "cdn": { $0.cdn.map { .object($0.wireFields) } },
        "resproxy": { $0.resproxy.map { .object($0.wireFields) } },
        "dcproxy": { $0.dcproxy.map { .object($0.wireFields) } },
        "mobproxy": { $0.mobproxy.map { .object($0.wireFields) } },
        "pubproxy": { $0.pubproxy.map { .object($0.wireFields) } },
        "carrier": { $0.carrier.map { .object($0.wireFields) } },
        "satellite": { $0.satellite.map { .object($0.wireFields) } },
        "ssh": { $0.ssh.map { .object($0.wireFields) } },
        "smtp": { $0.smtp.map { .object($0.wireFields) } },
        "web": { $0.web.map { .array($0.map { .object($0.wireFields) }) } },
        "dns_resolver": { $0.dnsResolver.map { .object($0.wireFields) } },
        "bittorrent": { $0.bittorrent.map { .object($0.wireFields) } },
        "location": { $0.location.map { .object($0.wireFields) } },
        "asn": { $0.asn.map { .object($0.wireFields) } },
        "company": { $0.company.map { .object($0.wireFields) } },
        "hostname": { $0.hostname.map { .string($0) } },
        "abuse": { $0.abuse.map { .object($0.wireFields) } },
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
        providerName.map { fields["provider_name"] = .string($0) }
        return fields
    }
}

extension ClassDetail {
    var wireFields: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        provider.map { fields["provider"] = .string($0) }
        confidence.map { fields["confidence"] = .string($0) }
        lastSeen.map { fields["last_seen"] = .string($0) }
        providerName.map { fields["provider_name"] = .string($0) }
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
        providerName.map { fields["provider_name"] = .string($0) }
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

extension CarrierDetail {
    var wireFields: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        name.map { fields["name"] = .string($0) }
        mcc.map { fields["mcc"] = .string($0) }
        mnc.map { fields["mnc"] = .string($0) }
        country.map { fields["country"] = .string($0) }
        confidence.map { fields["confidence"] = .string($0) }
        return fields
    }
}

extension SatelliteDetail {
    var wireFields: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        provider.map { fields["provider"] = .string($0) }
        providerName.map { fields["provider_name"] = .string($0) }
        orbit.map { fields["orbit"] = .string($0) }
        segment.map { fields["segment"] = .string($0) }
        country.map { fields["country"] = .string($0) }
        asn.map { fields["asn"] = .int($0) }
        confidence.map { fields["confidence"] = .string($0) }
        return fields
    }
}

extension SshDetail {
    var wireFields: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        port.map { fields["port"] = .int($0) }
        banner.map { fields["banner"] = .string($0) }
        hostKeyFp.map { fields["host_key_fp"] = .string($0) }
        sessionOk.map { fields["session_ok"] = .bool($0) }
        firstSeen.map { fields["first_seen"] = .string($0) }
        lastSeen.map { fields["last_seen"] = .string($0) }
        return fields
    }
}

extension SmtpDetail {
    var wireFields: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        port.map { fields["port"] = .int($0) }
        banner.map { fields["banner"] = .string($0) }
        sessionOk.map { fields["session_ok"] = .bool($0) }
        firstSeen.map { fields["first_seen"] = .string($0) }
        lastSeen.map { fields["last_seen"] = .string($0) }
        return fields
    }
}

extension WebDetail {
    var wireFields: [String: JSONValue] {
        [
            "port": .int(port), "tls_ok": .bool(tlsOk), "session_ok": .bool(sessionOk),
            "status_code": .int(statusCode), "server": .string(server), "location": .string(location),
            "title": .string(title), "cert_subject_cn": .string(certSubjectCn),
            "cert_subject_o": .string(certSubjectO), "cert_issuer_dn": .string(certIssuerDn),
            "cert_browser_trusted": .bool(certBrowserTrusted), "tls_version": .string(tlsVersion),
            "first_seen": .string(firstSeen), "last_seen": .string(lastSeen),
        ]
    }
}

extension DnsResolverDetail {
    var wireFields: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        port.map { fields["port"] = .int($0) }
        recursionAvailable.map { fields["recursion_available"] = .bool($0) }
        rcode.map { fields["rcode"] = .int($0) }
        answerCorrect.map { fields["answer_correct"] = .bool($0) }
        firstSeen.map { fields["first_seen"] = .string($0) }
        lastSeen.map { fields["last_seen"] = .string($0) }
        return fields
    }
}

extension BitTorrentDetail {
    var wireFields: [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        verified.map { fields["verified"] = .bool($0) }
        idMatchesIp.map { fields["id_matches_ip"] = .bool($0) }
        firstSeen.map { fields["first_seen"] = .string($0) }
        lastSeen.map { fields["last_seen"] = .string($0) }
        lastReachable.map { fields["last_reachable"] = .string($0) }
        daysSeen.map { fields["days_seen"] = .int($0) }
        numPorts.map { fields["num_ports"] = .int($0) }
        peakNumPorts.map { fields["peak_num_ports"] = .int($0) }
        indexer.map { fields["indexer"] = .bool($0) }
        clients.map { fields["clients"] = .array($0.map { .string($0) }) }
        return fields
    }
}

extension Location {
    var wireFields: [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "continent": .string(continent), "continent_name": .string(continentName),
            "country": .string(country), "country_name": .string(countryName),
            "timezone": .string(timezone), "currency_code": .string(currencyCode),
            "currency_name": .string(currencyName), "currency_symbol": .string(currencySymbol),
            "flag_emoji": .string(flagEmoji), "flag_unicode": .string(flagUnicode),
        ]
        region.map { fields["region"] = .string($0) }
        regionCode.map { fields["region_code"] = .string($0) }
        city.map { fields["city"] = .string($0) }
        postalCode.map { fields["postal_code"] = .string($0) }
        latitude.map { fields["latitude"] = .double($0) }
        longitude.map { fields["longitude"] = .double($0) }
        accuracyRadius.map { fields["accuracy_radius"] = .int($0) }
        geonameId.map { fields["geoname_id"] = .string($0) }
        dmaCode.map { fields["dma_code"] = .string($0) }
        lastChanged.map { fields["last_changed"] = .string($0) }
        return fields
    }
}

extension Asn {
    var wireFields: [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "asn": .int(asn), "name": .string(name), "domain": .string(domain),
            "type": .string(type), "prefix": .string(prefix),
        ]
        country.map { fields["country"] = .string($0) }
        rpkiStatus.map { fields["rpki_status"] = .string($0) }
        return fields
    }
}

extension Company {
    var wireFields: [String: JSONValue] {
        var fields: [String: JSONValue] = ["name": .string(name), "domain": .string(domain)]
        type.map { fields["type"] = .string($0) }
        country.map { fields["country"] = .string($0) }
        return fields
    }
}

extension AbuseContact {
    var wireFields: [String: JSONValue] {
        var fields: [String: JSONValue] = ["email": .string(email)]
        name.map { fields["name"] = .string($0) }
        phone.map { fields["phone"] = .string($0) }
        address.map { fields["address"] = .string($0) }
        country.map { fields["country"] = .string($0) }
        network.map { fields["network"] = .string($0) }
        validated.map { fields["validated"] = .bool($0) }
        unvalidatedSince.map { fields["unvalidated_since"] = .string($0) }
        return fields
    }
}

extension JSONValue {
    /// The same value with every whole-number double read as an integer, so a
    /// served `0` and a decoded `0.0` compare equal while `-33.86785` stays as it
    /// is.
    var numbersNormalized: JSONValue {
        switch self {
        case .double(let value):
            if let whole = Int(exactly: value) {
                return .int(whole)
            }
            return self
        case .array(let items): return .array(items.map(\.numbersNormalized))
        case .object(let members): return .object(members.mapValues(\.numbersNormalized))
        default: return self
        }
    }
}
