/// Whether an address is a bogon: private, loopback, link-local, documentation,
/// multicast or otherwise not routable on the public internet, including the
/// IPv6 equivalents and the 6to4 and Teredo ranges that wrap them.
///
/// These can never be VPN or proxy infrastructure, so the client answers them
/// itself and they never cost a request. The same check is available as
/// ``VPNDetectionClient/isBogon(_:)`` on a client you already hold.
public func isBogon(_ ip: String) -> Bool {
    // Routed on the colon rather than by trying both tables, so the 4-in-6
    // forms (::ffff:10.0.0.1) match the v6 ranges exactly as every other
    // VPNDetection client library resolves them.
    if ip.contains(":") {
        guard let address = V6Address(ip) else {
            return false
        }
        return bogonRangesV6.contains { $0.contains(address) }
    }
    guard let address = v4ToInt(ip) else {
        return false
    }
    return bogonRangesV4.contains { $0.contains(address) }
}

extension LookupResult {
    /// The answer a bogon gets, in the full shape the API serves at its widest
    /// plan: every flag present and false, every detail object present and empty.
    ///
    /// `isBogon` is set so a caller can always tell a locally computed answer
    /// from a served one. Note this is deliberately the WIDEST shape regardless
    /// of your plan, so do not infer which fields your plan includes from it.
    static func bogon(_ ip: String) -> LookupResult {
        let vpn = VpnDetail(provider: nil, lastSeen: nil, confidence: nil, method: nil)
        let classDetail = ClassDetail(provider: nil, confidence: nil, lastSeen: nil)
        let proxy = ProxyDetail(
            provider: nil, firstSeen: nil, lastSeen: nil,
            hits: nil, hitsDaysPct: nil, providersNum: nil,
        )
        return LookupResult(
            ip: ip, isVpn: false, isBogon: true,
            isHosting: false, isRelay: false, isTor: false, isCdn: false,
            isResproxy: false, isDcproxy: false, isMobproxy: false,
            vpn: vpn, hosting: classDetail, relay: classDetail, tor: classDetail,
            cdn: classDetail, resproxy: proxy, dcproxy: proxy, mobproxy: proxy,
        )
    }
}

// A Swift global is initialized on first use behind a `swift_once`, so the table
// costs nothing to a consumer that never looks an address up. A range that does
// not parse can only mean a broken generated table, so it fails loudly rather
// than quietly shrinking the set of addresses answered locally.
let bogonRangesV4: [V4Range] = Bogons.v4.map {
    guard let range = V4Range($0) else {
        preconditionFailure("generated bogon range \($0) does not parse")
    }
    return range
}

let bogonRangesV6: [V6Range] = Bogons.v6.map {
    guard let range = V6Range($0) else {
        preconditionFailure("generated bogon range \($0) does not parse")
    }
    return range
}

struct V4Range {
    let network: UInt32
    let mask: UInt32

    init?(_ cidr: String) {
        let parts = cidr.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let bits = UInt32(parts[1]), bits <= 32,
            let address = v4ToInt(String(parts[0]))
        else {
            return nil
        }
        self.mask = bits == 0 ? 0 : ~UInt32(0) << (32 - bits)
        self.network = address & self.mask
    }

    func contains(_ address: UInt32) -> Bool { address & mask == network }
}

struct V6Range {
    let network: V6Address
    let mask: V6Address

    init?(_ cidr: String) {
        let parts = cidr.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let bits = UInt32(parts[1]), bits <= 128,
            let address = V6Address(String(parts[0]))
        else {
            return nil
        }
        self.mask = V6Address(prefixLength: bits)
        self.network = address.masked(by: self.mask)
    }

    func contains(_ address: V6Address) -> Bool { address.masked(by: mask) == network }
}

// A 128 bit address as two halves. The stdlib's UInt128 would be tidier but it
// only exists from macOS 15 and iOS 18, far above this package's floor.
struct V6Address: Hashable {
    let high: UInt64
    let low: UInt64

    init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }

    init(prefixLength bits: UInt32) {
        self.high = bits == 0 ? 0 : ~UInt64(0) << (64 - min(bits, 64))
        self.low = bits <= 64 ? 0 : ~UInt64(0) << (128 - bits)
    }

    func masked(by mask: V6Address) -> V6Address {
        V6Address(high: high & mask.high, low: low & mask.low)
    }
}

func v4ToInt(_ ip: String) -> UInt32? {
    let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else {
        return nil
    }
    var value: UInt32 = 0
    for part in parts {
        guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
            let byte = UInt32(part), byte <= 255
        else {
            return nil
        }
        value = value << 8 | byte
    }
    return value
}

extension V6Address {
    // Handles the `::` run and a trailing IPv4 literal (::ffff:1.2.3.4), which
    // several of the canonical ranges use.
    init?(_ ip: String) {
        var text = Substring(ip)
        if let lastColon = ip.lastIndex(of: ":"), ip[ip.index(after: lastColon)...].contains(".") {
            guard let embedded = v4ToInt(String(ip[ip.index(after: lastColon)...])) else {
                return nil
            }
            text = ip[...lastColon] + "\(String(embedded >> 16, radix: 16)):"
                + String(embedded & 0xffff, radix: 16)
        }

        let groups: [Substring]
        if let run = text.firstRange(of: "::") {
            let head = text[text.startIndex..<run.lowerBound].split(separator: ":")
            let tail = text[run.upperBound...].split(separator: ":")
            guard head.count + tail.count <= 8 else {
                return nil
            }
            groups = head + Array(repeating: Substring("0"), count: 8 - head.count - tail.count) + tail
        } else {
            groups = text.split(separator: ":", omittingEmptySubsequences: false)
            guard groups.count == 8 else {
                return nil
            }
        }

        var high: UInt64 = 0
        var low: UInt64 = 0
        for (index, group) in groups.enumerated() {
            guard (1...4).contains(group.count), group.allSatisfy(\.isHexDigit),
                let word = UInt64(group, radix: 16)
            else {
                return nil
            }
            if index < 4 {
                high = high << 16 | word
            } else {
                low = low << 16 | word
            }
        }
        self.init(high: high, low: low)
    }
}
