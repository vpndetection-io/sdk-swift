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

    public let vpn: VpnDetail?
    public let hosting: ClassDetail?
    public let relay: ClassDetail?
    public let tor: ClassDetail?
    public let cdn: ClassDetail?
    public let resproxy: ProxyDetail?
    public let dcproxy: ProxyDetail?
    public let mobproxy: ProxyDetail?
}

/// What is known about the VPN attribution.
///
/// Every key is present when the object is populated, empty values included; the
/// object is empty when `isVpn` is false. `confidence` and `method` are max only,
/// so on a lower plan they are absent from a populated object rather than empty.
public struct VpnDetail: Sendable, Hashable {
    /// The VPN provider, or an empty string for an unattributed range.
    public let provider: String?
    /// The most recent date this address was observed, as `YYYY-MM-DD`.
    public let lastSeen: String?
    /// How strongly the attribution is supported. Max only.
    public let confidence: String?
    /// How the address was attributed to the provider. Max only.
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
        self.vpn = body.vpn.map { VpnDetail($0.value1) }
        self.hosting = body.hosting.map { ClassDetail($0.value1) }
        self.relay = body.relay.map { ClassDetail($0.value1) }
        self.tor = body.tor.map { ClassDetail($0.value1) }
        self.cdn = body.cdn.map { ClassDetail($0.value1) }
        self.resproxy = body.resproxy.map { ProxyDetail($0.value1) }
        self.dcproxy = body.dcproxy.map { ProxyDetail($0.value1) }
        self.mobproxy = body.mobproxy.map { ProxyDetail($0.value1) }
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
