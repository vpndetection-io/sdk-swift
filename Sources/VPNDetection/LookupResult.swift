/// What a lookup answers.
///
/// An **optional** member is one your plan does not include. It never means "we
/// could not check", so `nil` and `false` are genuinely different answers: `nil`
/// is "not in your plan", `false` is "checked, and no". Write `?? false` when
/// you only care whether the address is flagged, and compare against `nil` when
/// the difference matters.
///
/// The same holds inside a shared object: `location?.city` is `nil` on Unlimited,
/// the free plan.
///
/// A detail object that is present but empty means the flag above it is false,
/// and `web` is an empty list when `isWeb` is. A populated one always carries
/// every one of its keys.
public struct LookupResult: Sendable, Hashable {
    /// The address that was looked up, normalized.
    public let ip: String
    /// Whether the address is VPN infrastructure. Every plan includes this.
    public let isVpn: Bool
    /// Whether the address is reserved space (private, loopback, documentation and
    /// the like), which this package answers locally without a request. A served
    /// answer carries the API's own `is_bogon`, and this reads it.
    public let isBogon: Bool

    public let isHosting: Bool?
    public let isRelay: Bool?
    public let isTor: Bool?
    public let isCdn: Bool?
    public let isResproxy: Bool?
    public let isDcproxy: Bool?
    public let isMobproxy: Bool?
    /// Whether a public proxy, one anyone can connect through, listens on the
    /// address or sends its traffic out from it. On a paid plan.
    public let isPubproxy: Bool?
    /// Whether the address is announced from many places at once, as a public
    /// DNS resolver's or a CDN's edge is. Every answer carries it, with or
    /// without a key.
    public let isAnycast: Bool?
    /// Whether the address is a mobile carrier's, where many phones can share
    /// one address. On a paid plan.
    public let isCarrier: Bool?
    /// Whether the address is a satellite operator's. On a paid plan.
    public let isSatellite: Bool?
    /// Whether an SSH server answered on the address. On a paid plan.
    public let isSsh: Bool?
    /// Whether a mail server answered on the address. On a paid plan.
    public let isSmtp: Bool?
    /// Whether a web server answered on the address, on port 80 or 443. On a
    /// paid plan.
    public let isWeb: Bool?
    /// Whether an open DNS resolver answered on the address. On a paid plan.
    public let isDnsResolver: Bool?
    /// Whether a BitTorrent client was seen on the address in the last 90 days.
    /// On a paid plan.
    public let isBittorrent: Bool?
    /// Whether an automated client uses the address, such as a search engine's
    /// or an AI company's crawler, an uptime monitor, an internet scanner or a
    /// webhook sender. Every answer carries it, with or without a key.
    public let isBot: Bool?

    public let vpn: VpnDetail?
    public let hosting: ClassDetail?
    public let relay: ClassDetail?
    public let tor: ClassDetail?
    public let cdn: ClassDetail?
    public let resproxy: ProxyDetail?
    public let dcproxy: ProxyDetail?
    public let mobproxy: ProxyDetail?
    /// Detail for `isPubproxy`. Empty when it is false. On a paid plan.
    public let pubproxy: PubproxyDetail?
    /// Detail for `isCarrier`. Empty when it is false. On a paid plan.
    public let carrier: CarrierDetail?
    /// Detail for `isSatellite`. Empty when it is false. On a paid plan.
    public let satellite: SatelliteDetail?
    /// Detail for `isSsh`. Empty when it is false. On a paid plan.
    public let ssh: SshDetail?
    /// Detail for `isSmtp`. Empty when it is false. On a paid plan.
    public let smtp: SmtpDetail?
    /// Detail for `isWeb`: a row per port that answered, lowest first, and an
    /// empty list when it is false. On a paid plan.
    public let web: [WebDetail]?
    /// Detail for `isDnsResolver`. Empty when it is false. On a paid plan.
    public let dnsResolver: DnsResolverDetail?
    /// Detail for `isBittorrent`. Empty when it is false. On a paid plan.
    public let bittorrent: BitTorrentDetail?
    /// Detail for `isBot`: whose bot uses the address, what it does and whether
    /// its operator vouches for the address. Empty when it is false. On a paid
    /// plan.
    public let bot: BotDetail?
    /// Where the address is. Every answer carries it, with or without a key; its
    /// finer members, from the region down, on a paid plan.
    public let location: Location?
    /// The AS announcing the address. Every answer carries it, with or without
    /// a key.
    public let asn: Asn?
    /// Who uses the address. On a paid plan.
    public let company: Company?
    /// The name the address's reverse DNS (PTR) record points to, or an empty
    /// string when it has none. Every answer carries it, with or without a key.
    public let hostname: String?
    /// Where to report abuse from the address. On a paid plan.
    public let abuse: AbuseContact?
    /// The agent the lookup's `userAgent` names and whether this address bears
    /// it out, when one was sent, on a paid plan or the trial. `nil` when none
    /// was, and on a bogon, which is answered locally.
    public let userAgent: UserAgentVerdict?
    /// On answers to a key on the free plan only: `false` while its organization's
    /// trial of every field lasts, `true` once the answer has Unlimited's.
    public let trialExpired: Bool?
    /// On every answer to a key on a paid plan, and on no other: `false` while
    /// the answer has every field, `true` once its organization's overage cap
    /// is reached and the answer has Unlimited's. Lookups answered past the cap
    /// are not billed; raising or removing the cap in Billing turns it `false`
    /// again.
    public let capReached: Bool?
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
    /// The name the provider catalog gives `provider`, the ID to key on; an empty
    /// string where the catalog names none.
    public let providerName: String?

    public var isEmpty: Bool {
        provider == nil && lastSeen == nil && confidence == nil && method == nil && providerName == nil
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
    /// The name the provider catalog gives `provider`, the ID to key on; an empty
    /// string where the catalog names none.
    public let providerName: String?

    public var isEmpty: Bool {
        provider == nil && confidence == nil && lastSeen == nil && providerName == nil
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
    /// The name the provider catalog gives `provider`, the ID to key on; an empty
    /// string where the catalog names none.
    public let providerName: String?

    public var isEmpty: Bool {
        provider == nil && firstSeen == nil && lastSeen == nil
            && hits == nil && hitsDaysPct == nil && providersNum == nil && providerName == nil
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

/// The mobile network whose address space this is.
public struct CarrierDetail: Sendable, Hashable {
    /// The mobile carrier.
    public let name: String?
    /// Its mobile country code.
    public let mcc: String?
    /// Its mobile network code.
    public let mnc: String?
    /// ISO 3166 country code.
    public let country: String?
    /// `high`, `medium` or `low`.
    public let confidence: String?

    public var isEmpty: Bool {
        name == nil && mcc == nil && mnc == nil && country == nil && confidence == nil
    }
}

/// The satellite operator whose address space this is.
public struct SatelliteDetail: Sendable, Hashable {
    /// The operator's ID in Satellite IP Provider.
    public let provider: String?
    /// The operator's name.
    public let providerName: String?
    /// The orbit: `leo`, `meo` or `geo`.
    public let orbit: String?
    /// Who the space serves, such as consumer or maritime.
    public let segment: String?
    /// ISO 3166 country code.
    public let country: String?
    /// The AS the operator announces it from.
    public let asn: Int?
    /// `high`, `medium` or `low`.
    public let confidence: String?

    public var isEmpty: Bool {
        provider == nil && providerName == nil && orbit == nil && segment == nil && country == nil
            && asn == nil && confidence == nil
    }
}

/// The SSH server that answered on the address.
public struct SshDetail: Sendable, Hashable {
    /// The port the server answered on.
    public let port: Int?
    /// Its banner.
    public let banner: String?
    /// Its host key's fingerprint.
    public let hostKeyFp: String?
    /// A session was set up.
    public let sessionOk: Bool?
    /// The first day it answered, as `YYYY-MM-DD`.
    public let firstSeen: String?
    /// The last day it did, as `YYYY-MM-DD`.
    public let lastSeen: String?

    public var isEmpty: Bool {
        port == nil && banner == nil && hostKeyFp == nil && sessionOk == nil && firstSeen == nil
            && lastSeen == nil
    }
}

/// The mail server that answered on the address.
public struct SmtpDetail: Sendable, Hashable {
    /// The port the server answered on.
    public let port: Int?
    /// Its banner.
    public let banner: String?
    /// A session was set up.
    public let sessionOk: Bool?
    /// The first day it answered, as `YYYY-MM-DD`.
    public let firstSeen: String?
    /// The last day it did, as `YYYY-MM-DD`.
    public let lastSeen: String?

    public var isEmpty: Bool {
        port == nil && banner == nil && sessionOk == nil && firstSeen == nil && lastSeen == nil
    }
}

/// One port of the address that answered as a web server.
public struct WebDetail: Sendable, Hashable {
    /// 80 or 443.
    public let port: Int
    /// A TLS handshake completed.
    public let tlsOk: Bool
    /// An HTTP response came back.
    public let sessionOk: Bool
    /// Its status, 0 where none came.
    public let statusCode: Int
    /// Its `Server` header.
    public let server: String
    /// Where it redirected.
    public let location: String
    /// The page's title.
    public let title: String
    /// The certificate's subject common name.
    public let certSubjectCn: String
    /// Its subject organization.
    public let certSubjectO: String
    /// Its issuer.
    public let certIssuerDn: String
    /// Browsers trust it.
    public let certBrowserTrusted: Bool
    /// The TLS version negotiated, empty without TLS.
    public let tlsVersion: String
    /// The first day the port was open, as `YYYY-MM-DD`.
    public let firstSeen: String
    /// The last day it was, as `YYYY-MM-DD`.
    public let lastSeen: String
}

/// The open DNS resolver that answered on the address.
public struct DnsResolverDetail: Sendable, Hashable {
    /// The port it answered on.
    public let port: Int?
    /// It offered recursion.
    public let recursionAvailable: Bool?
    /// Its answer's response code.
    public let rcode: Int?
    /// Its answer was right.
    public let answerCorrect: Bool?
    /// The first day it answered, as `YYYY-MM-DD`.
    public let firstSeen: String?
    /// The last day it did, as `YYYY-MM-DD`.
    public let lastSeen: String?

    public var isEmpty: Bool {
        port == nil && recursionAvailable == nil && rcode == nil && answerCorrect == nil
            && firstSeen == nil && lastSeen == nil
    }
}

/// The BitTorrent clients seen on the address over the last 90 days.
public struct BitTorrentDetail: Sendable, Hashable {
    /// A client here answered, or two or more reported it at once.
    public let verified: Bool?
    /// A client here derived its node ID from the address (BEP 42).
    public let idMatchesIp: Bool?
    /// The first day a client was seen here, as `YYYY-MM-DD`.
    public let firstSeen: String?
    /// The last day, as `YYYY-MM-DD`.
    public let lastSeen: String?
    /// The last day one answered, empty when none did.
    public let lastReachable: String?
    /// On how many days.
    public let daysSeen: Int?
    /// Distinct ports over the window.
    public let numPorts: Int?
    /// The most on one day.
    public let peakNumPorts: Int?
    /// A DHT indexer rather than people.
    public let indexer: Bool?
    /// The two-letter codes its clients name themselves by.
    public let clients: [String]?

    public var isEmpty: Bool {
        verified == nil && idMatchesIp == nil && firstSeen == nil && lastSeen == nil
            && lastReachable == nil && daysSeen == nil && numPorts == nil && peakNumPorts == nil
            && indexer == nil && clients == nil
    }
}

/// The bot that uses the address: its operator, the bots it serves or claimed
/// to be, what they do, and how that is known.
public struct BotDetail: Sendable, Hashable {
    /// The bot operator's ID, or an empty string where no operator is known.
    public let provider: String?
    /// The operator's name, or an empty string where no operator is known.
    public let providerName: String?
    /// The bots the address serves, as their user agents name them (`Googlebot`,
    /// `GPTBot`), in the order served; for an address that is not verified, the
    /// bots it claimed to be. Empty where none is named.
    public let agents: [String]?
    /// What those bots do, such as `search_engine`, `ai_training`, `ai_search`,
    /// `monitoring`, `scanner` or `webhook`, in the order served. Empty where
    /// unknown.
    public let categories: [String]?
    /// Whether the operator vouches for the address, so the bots in `agents`
    /// really are its.
    public let verified: Bool?
    /// `verified`, `declared` (it names itself a bot that cannot be verified),
    /// `spoofed` (it claimed a bot whose operator vouches for other addresses) or
    /// `undeclared` (it hides as a browser and behaves as automation).
    public let identity: String?
    /// How a verified address verified: `list`, `rdns` or `owner`; an empty
    /// string when it is not verified.
    public let verifiedBy: String?
    /// `high`, `medium` or `low`.
    public let confidence: String?
    /// The first day the address was seen as such, as `YYYY-MM-DD`.
    public let firstSeen: String?
    /// The last day it was, as `YYYY-MM-DD`.
    public let lastSeen: String?

    public var isEmpty: Bool {
        provider == nil && providerName == nil && agents == nil && categories == nil && verified == nil
            && identity == nil && verifiedBy == nil && confidence == nil && firstSeen == nil
            && lastSeen == nil
    }
}

/// What a lookup's user agent says the client is, and whether the address bears
/// it out.
public struct UserAgentVerdict: Sendable, Hashable {
    /// The agent the user agent names, such as `Googlebot` or `Chrome`;
    /// `Unknown` where it names none.
    public let agent: String
    /// What kind of client the user agent says it is: `browser`, `inapp`,
    /// `automation`, `bot`, `ai-bot`, `http-client` or `unknown`.
    public let kind: String
    /// Whether the address bears the agent out.
    public let verdict: Verdict

    /// Whether the address bears a user agent out. A value the API adds after
    /// this release reads as itself, with ``Vocabulary/isKnown`` false.
    public struct Verdict: Vocabulary {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// The agent's operator vouches for this address as it.
        public static let verified = Verdict(rawValue: "verified")
        /// The operator of a bot that publishes its addresses, or whose
        /// registered space it uses, does not vouch for this one, or this address
        /// posed as the bot before.
        public static let spoofed = Verdict(rawValue: "spoofed")
        /// A bot no published list or registered space can confirm.
        public static let unverifiable = Verdict(rawValue: "unverifiable")
        /// A browser, an app or a script.
        public static let notBot = Verdict(rawValue: "not_bot")

        public static let known: [Verdict] = [.verified, .spoofed, .unverifiable, .notBot]
    }
}

/// Where the address is. The first ten members are set whenever the object is,
/// an empty string where not known; the rest, from `region` down, on a paid
/// plan, and `nil` on Unlimited.
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
    /// The region, a state or province.
    public let region: String?
    /// The ISO 3166-2 region code.
    public let regionCode: String?
    public let city: String?
    public let postalCode: String?
    /// The latitude of the city.
    public let latitude: Double?
    /// The longitude of the city.
    public let longitude: Double?
    /// The radius in km holding the true location with 67% confidence; 20000
    /// for an address announced everywhere, as an anycast one is.
    public let accuracyRadius: Int?
    /// The GeoNames ID of the city.
    public let geonameId: String?
    /// The US TV market (DMA) code, empty outside the US.
    public let dmaCode: String?
    /// The day the range's location last changed.
    public let lastChanged: String?
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
    /// The country the AS's registry assigned it to. Every answer carries it;
    /// an answer without it is refused.
    public let country: String?
    /// The announcement's RPKI status: `valid`, `invalid` or `not_found`. Every
    /// answer carries it; an answer without it is refused.
    public let rpkiStatus: String?
}

/// Who uses the address. Every member is set whenever the object is, an empty
/// string where no record covers the address.
public struct Company: Sendable, Hashable {
    /// Who uses the address.
    public let name: String
    /// Their domain.
    public let domain: String
    /// `hosting`, `isp`, `business`, `education` or `government`.
    public let type: String?
    /// ISO 3166 country code.
    public let country: String?
}

/// Where to report abuse from the address. Every member is set whenever the
/// object is, an empty string where no record covers the address.
public struct AbuseContact: Sendable, Hashable {
    /// Where to report abuse from the address.
    public let email: String
    /// The contact.
    public let name: String?
    /// Its phone number.
    public let phone: String?
    /// Its postal address.
    public let address: String?
    /// ISO 3166 country code.
    public let country: String?
    /// The registry block it was derived from.
    public let network: String?
    /// ARIN reports the contact answered its yearly validation.
    public let validated: Bool?
    /// Since when it has not.
    public let unvalidatedSince: String?
}

// The one place a wire payload becomes the public shape. Absent-versus-false
// survives for free: every tier-gated member is already an Optional, so copying
// it across cannot collapse `false` into "not in your plan".
extension LookupResult {
    init(_ body: Components.Schemas.LookupResponse) throws {
        self.ip = body.ip
        self.isVpn = body.isVpn
        self.isBogon = body.isBogon ?? false
        self.isHosting = body.isHosting
        self.isRelay = body.isRelay
        self.isTor = body.isTor
        self.isCdn = body.isCdn
        self.isResproxy = body.isResproxy
        self.isDcproxy = body.isDcproxy
        self.isMobproxy = body.isMobproxy
        self.isPubproxy = body.isPubproxy
        self.isAnycast = body.isAnycast
        self.isCarrier = body.isCarrier
        self.isSatellite = body.isSatellite
        self.isSsh = body.isSsh
        self.isSmtp = body.isSmtp
        self.isWeb = body.isWeb
        self.isDnsResolver = body.isDnsResolver
        self.isBittorrent = body.isBittorrent
        self.isBot = body.isBot
        self.vpn = try body.vpn.map { try VpnDetail($0.value1) }
        self.hosting = try body.hosting.map { try ClassDetail($0.value1) }
        self.relay = try body.relay.map { try ClassDetail($0.value1) }
        self.tor = try body.tor.map { try ClassDetail($0.value1) }
        self.cdn = try body.cdn.map { try ClassDetail($0.value1) }
        self.resproxy = try body.resproxy.map { try ProxyDetail($0.value1) }
        self.dcproxy = try body.dcproxy.map { try ProxyDetail($0.value1) }
        self.mobproxy = try body.mobproxy.map { try ProxyDetail($0.value1) }
        self.pubproxy = try body.pubproxy.map { try PubproxyDetail($0.value1) }
        self.carrier = body.carrier.map { CarrierDetail($0.value1) }
        self.satellite = body.satellite.map { SatelliteDetail($0.value1) }
        self.ssh = try body.ssh.map { try SshDetail($0.value1) }
        self.smtp = try body.smtp.map { try SmtpDetail($0.value1) }
        self.web = try body.web?.map(WebDetail.init)
        self.dnsResolver = try body.dnsResolver.map { try DnsResolverDetail($0.value1) }
        self.bittorrent = try body.bittorrent.map { try BitTorrentDetail($0.value1) }
        self.bot = try body.bot.map { try BotDetail($0.value1) }
        self.location = body.location.map(Location.init)
        self.asn = body.asn.map(Asn.init)
        self.company = body.company.map(Company.init)
        self.hostname = body.hostname
        self.abuse = body.abuse.map(AbuseContact.init)
        self.userAgent = try body.userAgent.map { try UserAgentVerdict($0.value1) }
        self.trialExpired = body.trialExpired
        self.capReached = body.capReached
    }
}

extension VpnDetail {
    init(_ detail: Components.Schemas.VpnDetail) throws {
        self.provider = detail.provider
        self.lastSeen = try fullDate(detail.lastSeen, "vpn.last_seen")
        self.confidence = detail.confidence
        self.method = detail.method
        self.providerName = detail.providerName
    }
}

extension ClassDetail {
    init(_ detail: Components.Schemas.ClassDetail) throws {
        self.provider = detail.provider
        self.confidence = detail.confidence
        self.lastSeen = try fullDate(detail.lastSeen, "last_seen")
        self.providerName = detail.providerName
    }
}

extension ProxyDetail {
    init(_ detail: Components.Schemas.ProxyDetail) throws {
        self.provider = detail.provider
        self.firstSeen = try fullDate(detail.firstSeen, "first_seen")
        self.lastSeen = try fullDate(detail.lastSeen, "last_seen")
        self.hits = detail.hits
        self.hitsDaysPct = detail.hitsDaysPct
        self.providersNum = detail.providersNum
        self.providerName = detail.providerName
    }
}

extension PubproxyDetail {
    init(_ detail: Components.Schemas.PubproxyDetail) throws {
        self.entry = detail.entry
        self.exit = detail.exit
        self.protocols = detail.protocols
        self.numPorts = detail.numPorts
        self.numProxies = detail.numProxies
        self.lastSeen = try fullDate(detail.lastSeen, "pubproxy.last_seen")
        self.lastUsable = detail.lastUsable
    }
}

extension CarrierDetail {
    init(_ wire: Components.Schemas.CarrierDetail) {
        self.init(
            name: wire.name, mcc: wire.mcc, mnc: wire.mnc, country: wire.country,
            confidence: wire.confidence,
        )
    }

    static let empty = CarrierDetail(name: nil, mcc: nil, mnc: nil, country: nil, confidence: nil)
}

extension SatelliteDetail {
    init(_ wire: Components.Schemas.SatelliteDetail) {
        self.init(
            provider: wire.provider, providerName: wire.providerName, orbit: wire.orbit,
            segment: wire.segment, country: wire.country, asn: wire.asn.map { Int($0) },
            confidence: wire.confidence,
        )
    }

    static let empty = SatelliteDetail(
        provider: nil, providerName: nil, orbit: nil, segment: nil, country: nil, asn: nil,
        confidence: nil,
    )
}

extension SshDetail {
    init(_ wire: Components.Schemas.SshDetail) throws {
        try self.init(
            port: wire.port, banner: wire.banner, hostKeyFp: wire.hostKeyFp, sessionOk: wire.sessionOk,
            firstSeen: fullDate(wire.firstSeen, "ssh.first_seen"), lastSeen: fullDate(wire.lastSeen, "ssh.last_seen"),
        )
    }

    static let empty = SshDetail(
        port: nil, banner: nil, hostKeyFp: nil, sessionOk: nil, firstSeen: nil, lastSeen: nil,
    )
}

extension SmtpDetail {
    init(_ wire: Components.Schemas.SmtpDetail) throws {
        try self.init(
            port: wire.port, banner: wire.banner, sessionOk: wire.sessionOk,
            firstSeen: fullDate(wire.firstSeen, "smtp.first_seen"), lastSeen: fullDate(wire.lastSeen, "smtp.last_seen"),
        )
    }

    static let empty = SmtpDetail(port: nil, banner: nil, sessionOk: nil, firstSeen: nil, lastSeen: nil)
}

extension WebDetail {
    init(_ wire: Components.Schemas.WebDetail) throws {
        self.port = wire.port
        self.tlsOk = wire.tlsOk
        self.sessionOk = wire.sessionOk
        self.statusCode = wire.statusCode
        self.server = wire.server
        self.location = wire.location
        self.title = wire.title
        self.certSubjectCn = wire.certSubjectCn
        self.certSubjectO = wire.certSubjectO
        self.certIssuerDn = wire.certIssuerDn
        self.certBrowserTrusted = wire.certBrowserTrusted
        self.tlsVersion = wire.tlsVersion
        self.firstSeen = try requiredDate(wire.firstSeen, "web.first_seen")
        self.lastSeen = try requiredDate(wire.lastSeen, "web.last_seen")
    }
}

extension DnsResolverDetail {
    init(_ wire: Components.Schemas.DnsResolverDetail) throws {
        try self.init(
            port: wire.port, recursionAvailable: wire.recursionAvailable, rcode: wire.rcode,
            answerCorrect: wire.answerCorrect, firstSeen: fullDate(wire.firstSeen, "dns_resolver.first_seen"),
            lastSeen: fullDate(wire.lastSeen, "dns_resolver.last_seen"),
        )
    }

    static let empty = DnsResolverDetail(
        port: nil, recursionAvailable: nil, rcode: nil, answerCorrect: nil, firstSeen: nil, lastSeen: nil,
    )
}

extension BitTorrentDetail {
    init(_ wire: Components.Schemas.BitTorrentDetail) throws {
        try self.init(
            verified: wire.verified, idMatchesIp: wire.idMatchesIp,
            firstSeen: fullDate(wire.firstSeen, "bittorrent.first_seen"),
            lastSeen: fullDate(wire.lastSeen, "bittorrent.last_seen"), lastReachable: wire.lastReachable, daysSeen: wire.daysSeen,
            numPorts: wire.numPorts, peakNumPorts: wire.peakNumPorts, indexer: wire.indexer,
            clients: wire.clients,
        )
    }

    static let empty = BitTorrentDetail(
        verified: nil, idMatchesIp: nil, firstSeen: nil, lastSeen: nil, lastReachable: nil, daysSeen: nil,
        numPorts: nil, peakNumPorts: nil, indexer: nil, clients: nil,
    )
}

extension BotDetail {
    init(_ wire: Components.Schemas.BotDetail) throws {
        try self.init(
            provider: wire.provider, providerName: wire.providerName, agents: wire.agents,
            categories: wire.categories, verified: wire.verified, identity: wire.identity,
            verifiedBy: wire.verifiedBy, confidence: wire.confidence,
            firstSeen: fullDate(wire.firstSeen, "bot.first_seen"), lastSeen: fullDate(wire.lastSeen, "bot.last_seen"),
        )
    }

    static let empty = BotDetail(
        provider: nil, providerName: nil, agents: nil, categories: nil, verified: nil, identity: nil,
        verifiedBy: nil, confidence: nil, firstSeen: nil, lastSeen: nil,
    )
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
        self.region = wire.region
        self.regionCode = wire.regionCode
        self.city = wire.city
        self.postalCode = wire.postalCode
        self.latitude = wire.latitude
        self.longitude = wire.longitude
        self.accuracyRadius = wire.accuracyRadius
        self.geonameId = wire.geonameId
        self.dmaCode = wire.dmaCode
        self.lastChanged = wire.lastChanged
    }

    /// Every member present and empty or zero, as the API answers a bogon.
    static let empty = Location(
        continent: "", continentName: "", country: "", countryName: "", timezone: "",
        currencyCode: "", currencyName: "", currencySymbol: "", flagEmoji: "", flagUnicode: "",
        region: "", regionCode: "", city: "", postalCode: "", latitude: 0, longitude: 0,
        accuracyRadius: 0, geonameId: "", dmaCode: "", lastChanged: "",
    )
}

extension Asn {
    init(_ wire: WireAsn) {
        self.asn = Int(wire.asn)
        self.name = wire.name
        self.domain = wire.domain
        self.type = wire.type
        self.prefix = wire.prefix
        self.country = wire.country
        self.rpkiStatus = wire.rpkiStatus
    }

    /// AS 0 and every other member empty, as the API answers an address no
    /// announcement covers.
    static let empty = Asn(asn: 0, name: "", domain: "", type: "", prefix: "", country: "", rpkiStatus: "")
}

/// The spec's `Asn`, read in place of the generated type (the config's
/// `typeOverrides`). Every member is required, as the spec lists them, so an
/// answer missing one, or carrying a null, is refused; the public `Asn` keeps
/// `country` and `rpkiStatus` optional because 5.1.0 shipped them that way.
struct WireAsn: Codable, Hashable, Sendable {
    var asn: Int64
    var name: String
    var domain: String
    var type: String
    var prefix: String
    var country: String
    var rpkiStatus: String

    enum CodingKeys: String, CodingKey {
        case asn, name, domain, type, prefix, country
        case rpkiStatus = "rpki_status"
    }
}

extension UserAgentVerdict {
    init(_ wire: WireUserAgentVerdict) throws {
        self.agent = wire.agent
        self.kind = wire.kind
        self.verdict = try vocabulary(wire.verdict, "user_agent.verdict")
    }
}

/// The spec's `UserAgentVerdict`, read in place of the generated type (the
/// config's `typeOverrides`), whose closed `verdict` would fail the whole call
/// on a value the API adds. Every member is required, as the spec lists them.
struct WireUserAgentVerdict: Codable, Hashable, Sendable {
    var agent: String
    var kind: String
    var verdict: String
}

extension Company {
    init(_ wire: Components.Schemas.Company) {
        self.name = wire.name
        self.domain = wire.domain
        self.type = wire._type
        self.country = wire.country
    }

    /// Every member present and empty, as the API answers a bogon.
    static let empty = Company(name: "", domain: "", type: "", country: "")
}

extension AbuseContact {
    init(_ wire: Components.Schemas.AbuseContact) {
        self.email = wire.email
        self.name = wire.name
        self.phone = wire.phone
        self.address = wire.address
        self.country = wire.country
        self.network = wire.network
        self.validated = wire.validated
        self.unvalidatedSince = wire.unvalidatedSince
    }

    /// Every member present and empty, `validated` false, as the API answers a
    /// bogon.
    static let empty = AbuseContact(
        email: "", name: "", phone: "", address: "", country: "", network: "", validated: false,
        unvalidatedSince: "",
    )
}

// A `format: date` member reaches the generated type as a plain string, so
// nothing has checked it: `tomorrow` and 30 February came back as served.
private func fullDate(_ value: String?, _ member: String) throws -> String? {
    guard let value else {
        return nil
    }
    return try requiredDate(value, member)
}

private func requiredDate(_ value: String, _ member: String) throws -> String {
    guard RFC3339.isFullDate(value) else {
        throw VPNDetectionError.unreadable("\(member) \(value.debugDescription) is no YYYY-MM-DD date")
    }
    return value
}
