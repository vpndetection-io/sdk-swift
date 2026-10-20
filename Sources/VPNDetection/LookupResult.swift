/// What a lookup answers.
///
/// An **optional** member is one your plan does not include. It never means "we
/// could not check", so `nil` and `false` are genuinely different answers: `nil`
/// is "not in your plan", `false` is "checked, and no". Write `?? false` when
/// you only care whether the address is flagged, and compare against `nil` when
/// the difference matters.
///
/// A detail object that is present but empty means the flag above it is false.
/// A populated one always carries every one of its keys.
public struct LookupResult: Sendable, Hashable {
    /// The address that was looked up, normalized.
    public let ip: String
    /// Whether the address is VPN infrastructure. Every plan includes this.
    public let isVpn: Bool
    /// Set when this answer was computed locally rather than served.
    public let isBogon: Bool

    public let isHosting: Bool?
    public let isRelay: Bool?
    public let isTor: Bool?
    public let isCdn: Bool?
    public let isResproxy: Bool?
    public let isDcproxy: Bool?
    public let isMobproxy: Bool?
    /// Whether a public proxy, one anyone can connect through, listens on the
    /// address or sends its traffic out from it. Every paid plan.
    public let isPubproxy: Bool?

    public let vpn: VpnDetail?
    public let hosting: ClassDetail?
    public let relay: ClassDetail?
    public let tor: ClassDetail?
    public let cdn: ClassDetail?
    public let resproxy: ProxyDetail?
    public let dcproxy: ProxyDetail?
    public let mobproxy: ProxyDetail?
    /// Detail for `isPubproxy`. Empty when it is false. Every paid plan.
    public let pubproxy: PubproxyDetail?
    /// Where the address is. Every keyed answer carries it, free and paid.
    public let location: Location?
    /// The AS announcing the address. Every keyed answer carries it, free and
    /// paid.
    public let asn: Asn?
}

/// What is known about the VPN attribution.
///
/// Every key is present when the object is populated, empty values included; the
/// object is empty when `isVpn` is false. `method` is deprecated: no plan is
/// answered with it since 2026-10-20, so it is `nil`.
public struct VpnDetail: Sendable, Hashable {
    /// The VPN provider, or an empty string for an unattributed range.
    public let provider: String?
    /// The most recent date this address was observed, as `YYYY-MM-DD`.
    public let lastSeen: String?
    /// How strongly the attribution is supported.
    public let confidence: String?
    /// Deprecated: no plan is answered with it since 2026-10-20, so it is always
    /// `nil`; read `confidence` instead. It goes in the next major.
    public let method: String?

    public var isEmpty: Bool {
        provider == nil && lastSeen == nil && confidence == nil && method == nil
    }
}

/// The shared detail shape for the hosting, relay, tor and cdn datasets.
public struct ClassDetail: Sendable, Hashable {
    /// The provider, or an empty string where the dataset has none.
    public let provider: String?
    /// How strongly the classification is supported.
    public let confidence: String?
    /// The most recent date this address was observed, as `YYYY-MM-DD`.
    public let lastSeen: String?

    public var isEmpty: Bool {
        provider == nil && confidence == nil && lastSeen == nil
    }
}

/// The shared detail shape for the residential, datacenter and mobile proxy
/// families, measured over a rolling 90 day window.
public struct ProxyDetail: Sendable, Hashable {
    /// The proxy network, or an empty string where unattributed.
    public let provider: String?
    /// The earliest date within the window, as `YYYY-MM-DD`.
    public let firstSeen: String?
    /// The most recent date within the window, as `YYYY-MM-DD`.
    public let lastSeen: String?
    /// How many times the address was observed in the pool during the window.
    public let hits: Int?
    /// The share of days in the window on which the address was seen, as a
    /// percentage. A high value means a stable pool member rather than a one-off.
    public let hitsDaysPct: Int?
    /// How many distinct proxy networks this address was seen in.
    public let providersNum: Int?

    public var isEmpty: Bool {
        provider == nil && firstSeen == nil && lastSeen == nil
            && hits == nil && hitsDaysPct == nil && providersNum == nil
    }
}

/// The address in Public Proxy IP, open proxies anyone can connect through, over
/// a rolling 90 day window. It covers both ends of a proxy: the address it
/// listens on and the address its traffic leaves from.
public struct PubproxyDetail: Sendable, Hashable {
    /// Whether a public proxy listens on this address.
    public let entry: Bool?
    /// Whether a public proxy's traffic leaves from this address.
    public let exit: Bool?
    /// The protocols of the proxies listening on or leaving from this address:
    /// `http`, `https` (an HTTP proxy that also tunnels HTTPS), `socks4` or
    /// `socks5`. Empty where only the address is known.
    public let protocols: [String]?
    /// How many distinct ports a public proxy listens on at this address; 0 when
    /// it is only an exit, or its port is not known.
    public let numPorts: Int?
    /// How many distinct public proxies' traffic left from this address; 0 when
    /// it is only an entry.
    public let numProxies: Int?
    /// The most recent date within the window a proxy on this address was seen,
    /// as `YYYY-MM-DD`.
    public let lastSeen: String?
    /// The most recent date within the window a request through a proxy on this
    /// address was answered, as `YYYY-MM-DD`, or an empty string when none was.
    public let lastUsable: String?

    public var isEmpty: Bool {
        entry == nil && exit == nil && protocols == nil && numPorts == nil && numProxies == nil
            && lastSeen == nil && lastUsable == nil
    }
}

/// Where the address is, to the country. Every property is set whenever the
/// object is, an empty string where it is not known.
public struct Location: Sendable, Hashable {
    /// The continent code, e.g. `EU`.
    public let continent: String
    public let continentName: String
    /// The ISO 3166-1 alpha-2 country code, e.g. `AT`.
    public let country: String
    public let countryName: String
    /// The IANA time zone, e.g. `Europe/Vienna`.
    public let timezone: String
    /// The ISO 4217 code of the country's currency, e.g. `EUR`.
    public let currencyCode: String
    public let currencyName: String
    public let currencySymbol: String
    public let flagEmoji: String
    /// The flag's code points, e.g. `U+1F1E6 U+1F1F9`.
    public let flagUnicode: String
}

/// The autonomous system announcing the address. `asn` is 0 and the rest empty
/// where no announcement covers it.
public struct Asn: Sendable, Hashable {
    /// The AS number, or 0.
    public let asn: Int
    /// The organization that operates the AS.
    public let name: String
    /// The AS operator's own registrable domain.
    public let domain: String
    /// `isp`, `hosting`, `education`, `government` or `business`.
    public let type: String
    /// The announced prefix covering the address, the most specific when
    /// several do.
    public let prefix: String
}

// The one place a wire payload becomes the public shape. Absent-versus-false
// survives for free: every tier-gated member is already an Optional, so copying
// it across cannot collapse `false` into "not in your plan".
extension LookupResult {
    init(_ body: Components.Schemas.LookupResponse) {
        self.ip = body.ip
        self.isVpn = body.isVpn
        self.isBogon = false
        self.isHosting = body.isHosting
        self.isRelay = body.isRelay
        self.isTor = body.isTor
        self.isCdn = body.isCdn
        self.isResproxy = body.isResproxy
        self.isDcproxy = body.isDcproxy
        self.isMobproxy = body.isMobproxy
        self.isPubproxy = body.isPubproxy
        self.vpn = body.vpn.map { VpnDetail($0.value1) }
        self.hosting = body.hosting.map { ClassDetail($0.value1) }
        self.relay = body.relay.map { ClassDetail($0.value1) }
        self.tor = body.tor.map { ClassDetail($0.value1) }
        self.cdn = body.cdn.map { ClassDetail($0.value1) }
        self.resproxy = body.resproxy.map { ProxyDetail($0.value1) }
        self.dcproxy = body.dcproxy.map { ProxyDetail($0.value1) }
        self.mobproxy = body.mobproxy.map { ProxyDetail($0.value1) }
        self.pubproxy = body.pubproxy.map { PubproxyDetail($0.value1) }
        self.location = body.location.map(Location.init)
        self.asn = body.asn.map(Asn.init)
    }
}

extension VpnDetail {
    init(_ detail: Components.Schemas.VpnDetail) {
        self.provider = detail.provider
        self.lastSeen = detail.lastSeen
        self.confidence = detail.confidence
        self.method = detail.method
    }
}

extension ClassDetail {
    init(_ detail: Components.Schemas.ClassDetail) {
        self.provider = detail.provider
        self.confidence = detail.confidence
        self.lastSeen = detail.lastSeen
    }
}

extension ProxyDetail {
    init(_ detail: Components.Schemas.ProxyDetail) {
        self.provider = detail.provider
        self.firstSeen = detail.firstSeen
        self.lastSeen = detail.lastSeen
        self.hits = detail.hits
        self.hitsDaysPct = detail.hitsDaysPct
        self.providersNum = detail.providersNum
    }
}

extension PubproxyDetail {
    init(_ detail: Components.Schemas.PubproxyDetail) {
        self.entry = detail.entry
        self.exit = detail.exit
        self.protocols = detail.protocols
        self.numPorts = detail.numPorts
        self.numProxies = detail.numProxies
        self.lastSeen = detail.lastSeen
        self.lastUsable = detail.lastUsable
    }
}

extension Location {
    init(_ wire: Components.Schemas.Location) {
        self.continent = wire.continent
        self.continentName = wire.continentName
        self.country = wire.country
        self.countryName = wire.countryName
        self.timezone = wire.timezone
        self.currencyCode = wire.currencyCode
        self.currencyName = wire.currencyName
        self.currencySymbol = wire.currencySymbol
        self.flagEmoji = wire.flagEmoji
        self.flagUnicode = wire.flagUnicode
    }

    /// Every member present and empty, as the API answers an address in no
    /// country.
    static let empty = Location(
        continent: "", continentName: "", country: "", countryName: "", timezone: "",
        currencyCode: "", currencyName: "", currencySymbol: "", flagEmoji: "", flagUnicode: "",
    )
}

extension Asn {
    init(_ wire: Components.Schemas.Asn) {
        self.asn = wire.asn
        self.name = wire.name
        self.domain = wire.domain
        self.type = wire._type
        self.prefix = wire.prefix
    }

    /// AS 0 and every other member empty, as the API answers an address no
    /// announcement covers.
    static let empty = Asn(asn: 0, name: "", domain: "", type: "", prefix: "")
}
