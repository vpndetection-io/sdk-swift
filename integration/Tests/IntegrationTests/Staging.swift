import AsyncHTTPClient
import Foundation
import HTTPTypes
import OpenAPIAsyncHTTPClient
import OpenAPIRuntime
import Testing
import VPNDetection

/// The staging fixtures every test file shares: one client per tier, one lookup
/// per tier, and the shape rules that hold whatever the plan.

let staging = URL(string: "https://api-staging.vpndetection.io")!

/// A stable VPN address, and the one the README teaches.
let probe = "45.83.91.1"

/// One answer per tier for the whole run, so the ladder and the shape tests
/// share a lookup rather than spending a request each. Tests run in parallel,
/// so the memo is an actor and holds the TASK, not the result: two readers
/// arriving together wait on one request instead of issuing two.
actor Answers {
    static let shared = Answers()

    private var pending: [Tier: Task<Fixture, any Error>] = [:]

    func fixture(for tier: Tier) async throws -> Fixture {
        if let task = pending[tier] {
            return try await task.value
        }
        let task = Task { try await lookupOnce(tier) }
        pending[tier] = task
        return try await task.value
    }
}

struct Fixture: Sendable {
    let tier: Tier
    let result: LookupResult
    /// Whether the key was on the wire. Without it the rung is indistinguishable
    /// from an unauthenticated one and every comparison against it is vacuous.
    let carriedKey: Bool
}

private func lookupOnce(_ tier: Tier) async throws -> Fixture {
    let transport = RecordingTransport(key: tier.key)
    let client = clientFor(tier, transport: transport)
    let result = try await client.lookup(probe)
    return Fixture(
        tier: tier,
        result: result,
        carriedKey: await transport.facts.contains { $0.carriedKey },
    )
}

func clientFor(_ tier: Tier, transport: RecordingTransport) -> VPNDetectionClient {
    VPNDetectionClient(
        options: .init(
            apiKey: tier.key.isEmpty ? nil : tier.key,
            baseURL: staging,
            transport: transport,
        ),
    )
}

/// A transport that records DERIVED facts about each request.
///
/// Only derived facts leave here. A failing expectation prints its operands and
/// these logs are public, so what is remembered is WHETHER the key was carried;
/// the request and the key itself never escape.
final class RecordingTransport: ClientTransport {
    struct Fact: Sendable, Equatable {
        let origin: String
        let path: String
        let carriedKey: Bool
    }

    private let key: String
    private let inner: any ClientTransport
    private let log = Log()

    init(key: String, inner: any ClientTransport = SharedTransport.value) {
        self.key = key
        self.inner = inner
    }

    var facts: [Fact] {
        get async { await log.facts }
    }

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let path = request.path ?? "/"
        let carried =
            !key.isEmpty
            && (path.contains(key) || request.headerFields.contains { $0.value.contains(key) })
        await log.record(
            Fact(
                origin: baseURL.absoluteString,
                path: String(path.split(separator: "?", maxSplits: 1)[0]),
                carriedKey: carried,
            ),
        )
        return try await inner.send(request, body: body, baseURL: baseURL, operationID: operationID)
    }

    private actor Log {
        var facts: [Fact] = []

        func record(_ fact: Fact) {
            facts.append(fact)
        }
    }
}

/// One `HTTPClient` for the process, held in a global so it is never
/// deallocated: AsyncHTTPClient's `deinit` traps in a debug build when a client
/// was not shut down. Redirects are refused, matching the library's own default
/// transport, because the download endpoint's `302` must reach the library
/// rather than the transport.
enum SharedTransport {
    static let value: any ClientTransport = AsyncHTTPClientTransport(
        configuration: .init(
            client: HTTPClient(
                eventLoopGroupProvider: .singleton,
                configuration: HTTPClient.Configuration(redirectConfiguration: .disallow),
            ),
        ),
    )
}

extension LookupResult {
    /// The wire fields this answer actually carried.
    ///
    /// Swift has no `raw` escape hatch by design, so the served set is read back
    /// off the typed members. That is sound here precisely because every
    /// tier-gated member is an `Optional` the mapper copies on presence: a `nil`
    /// member is a field the plan did not include, and a served `false` is
    /// still a member that is there.
    var servedFields: Set<String> {
        var fields: Set<String> = ["ip", "is_vpn"]
        let flags: [String: Bool?] = [
            "is_hosting": isHosting, "is_relay": isRelay, "is_tor": isTor, "is_cdn": isCdn,
            "is_resproxy": isResproxy, "is_dcproxy": isDcproxy, "is_mobproxy": isMobproxy,
        ]
        for (name, flag) in flags where flag != nil {
            fields.insert(name)
        }
        let details: [String: Bool] = [
            "vpn": vpn != nil, "hosting": hosting != nil, "relay": relay != nil,
            "tor": tor != nil, "cdn": cdn != nil, "resproxy": resproxy != nil,
            "dcproxy": dcproxy != nil, "mobproxy": mobproxy != nil,
        ]
        for (name, present) in details where present {
            fields.insert(name)
        }
        return fields
    }

    /// The flags this answer carried and answered `false` to. A mapper that
    /// copied on truthiness rather than presence would leave this empty.
    var flagsServedFalse: Set<String> {
        let flags: [String: Bool?] = [
            "is_vpn": isVpn, "is_hosting": isHosting, "is_relay": isRelay, "is_tor": isTor,
            "is_cdn": isCdn, "is_resproxy": isResproxy, "is_dcproxy": isDcproxy,
            "is_mobproxy": isMobproxy,
        ]
        return Set(flags.filter { $0.value == false }.keys)
    }
}

func assertServedByTier(_ fixture: Fixture) {
    #expect(fixture.result.ip == probe)
    #expect(fixture.result.isBogon == false, "a served answer is not a local one")
    if fixture.tier.secret != nil {
        // Bound first on purpose: a failing expectation prints its operands, and
        // the whole fixture is a wall of served data in a public log.
        let carriedKey = fixture.carriedKey
        #expect(carriedKey, "the \(fixture.tier.rawValue) key never reached the wire")
    }
    assertShape(fixture.result)
}

/// Holds on every plan: presence is the plan, the value is the answer.
func assertShape(_ result: LookupResult) {
    #expect(result.ip.isEmpty == false)

    assertVpn(result.vpn, flag: result.isVpn)
    assertClass("hosting", result.hosting, flag: result.isHosting)
    assertClass("relay", result.relay, flag: result.isRelay)
    assertClass("tor", result.tor, flag: result.isTor)
    assertClass("cdn", result.cdn, flag: result.isCdn)
    assertProxy("resproxy", result.resproxy, flag: result.isResproxy)
    assertProxy("dcproxy", result.dcproxy, flag: result.isDcproxy)
    assertProxy("mobproxy", result.mobproxy, flag: result.isMobproxy)
}

private func assertVpn(_ detail: VpnDetail?, flag: Bool) {
    guard let detail else {
        return
    }
    guard !detail.isEmpty else {
        #expect(flag == false, "vpn is empty, so is_vpn must be false")
        return
    }
    #expect(detail.provider != nil, "vpn is populated but carries no provider")
    #expect(detail.lastSeen != nil, "vpn is populated but carries no last_seen")
}

private func assertClass(_ name: String, _ detail: ClassDetail?, flag: Bool?) {
    guard let detail else {
        return
    }
    // A detail object without its flag would leave a caller reading the object
    // to find out whether the address is flagged at all.
    #expect(flag != nil, "\(name) is served without is_\(name)")
    guard !detail.isEmpty else {
        #expect(flag == false, "\(name) is empty, so is_\(name) must be false")
        return
    }
    #expect(detail.provider != nil, "\(name) is populated but carries no provider")
    #expect(detail.confidence != nil, "\(name) is populated but carries no confidence")
    #expect(detail.lastSeen != nil, "\(name) is populated but carries no last_seen")
}

private func assertProxy(_ name: String, _ detail: ProxyDetail?, flag: Bool?) {
    guard let detail else {
        return
    }
    #expect(flag != nil, "\(name) is served without is_\(name)")
    guard !detail.isEmpty else {
        #expect(flag == false, "\(name) is empty, so is_\(name) must be false")
        return
    }
    #expect(detail.provider != nil, "\(name) is populated but carries no provider")
    #expect(detail.firstSeen != nil, "\(name) is populated but carries no first_seen")
    #expect(detail.lastSeen != nil, "\(name) is populated but carries no last_seen")
    #expect(detail.hits != nil, "\(name) is populated but carries no hits")
    #expect(detail.hitsDaysPct != nil, "\(name) is populated but carries no hits_days_pct")
    #expect(detail.providersNum != nil, "\(name) is populated but carries no providers_num")
}
