import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
import VPNDetection

/// The published package looking addresses up against the staging API.
///
/// Nothing here pins a field COUNT. The tiers are asserted as a RELATION - each
/// one serves a superset of the tier below it - so a pricing change stays a
/// pricing change instead of arriving as a red SDK build.
@Suite("Staging lookups")
struct LookupTests {
    // The ladder needs two rungs to say anything. The unauthenticated one is
    // always there, so this only fires when no tier secret at all is set.
    static let ladder: ConditionTrait = .enabled(
        if: Tier.observable.count > 1,
        "no tier secret is set, so there is no ladder to compare",
    )

    @Test("an unauthenticated lookup answers ip and is_vpn")
    func unauthenticatedAnswersTheFreeShape() async throws {
        let fixture = try await Answers.shared.fixture(for: .unauth)

        #expect(fixture.result.ip == probe)
        assertServedByTier(fixture)
        print("testing against \(staging.absoluteString)")
    }

    @Test("a free key reaches the wire and its answer keeps the shape", Tier.free.needsKey)
    func freeKeepsTheShape() async throws {
        assertServedByTier(try await Answers.shared.fixture(for: .free))
    }

    @Test("a starter key reaches the wire and its answer keeps the shape", Tier.starter.needsKey)
    func starterKeepsTheShape() async throws {
        assertServedByTier(try await Answers.shared.fixture(for: .starter))
    }

    @Test("a scale key reaches the wire and its answer keeps the shape", Tier.scale.needsKey)
    func scaleKeepsTheShape() async throws {
        assertServedByTier(try await Answers.shared.fixture(for: .scale))
    }

    @Test("a max key reaches the wire and its answer keeps the shape", Tier.max.needsKey)
    func maxKeepsTheShape() async throws {
        assertServedByTier(try await Answers.shared.fixture(for: .max))
    }

    @Test("each tier serves a superset of the tier below", Self.ladder)
    func eachTierWidensTheOneBelow() async throws {
        var below: (tier: Tier, fields: Set<String>)?
        for tier in Tier.observable {
            let fixture = try await Answers.shared.fixture(for: tier)
            // Before anything is compared: a rung whose key never reached the
            // wire answered as an unauthenticated one, and containment against
            // it holds for reasons that have nothing to do with the plan.
            assertServedByTier(fixture)
            let fields = fixture.result.servedFields
            print("\(tier.rawValue): \(fields.count) fields")

            if let below {
                for field in below.fields {
                    #expect(
                        fields.contains(field),
                        "\(tier.rawValue) drops \(field), which \(below.tier.rawValue) serves",
                    )
                }
                // Without this a run whose keys all resolved to one plan would
                // pass: identical sets satisfy containment in both directions.
                if tier.widens {
                    #expect(
                        fields.count > below.fields.count,
                        "\(tier.rawValue) answers no more fields than \(below.tier.rawValue)",
                    )
                }
            }
            below = (tier, fields)
        }
    }

    // Swift states absent-versus-false in the type system: every tier-gated
    // member is an `Optional` and the mapper copies on presence, so a served
    // `false` cannot become "not in your plan" and there is no `raw` to compare
    // against. What served data can still show is the two halves that a mapper
    // ignoring presence would break: a paid rung really does add fields, and a
    // `false` the wire carried really does survive as `false` rather than `nil`.
    @Test("a paid tier adds fields, and a served false survives as false", Self.ladder)
    func absentIsNotFalseAgainstServedData() async throws {
        var below: (tier: Tier, fields: Set<String>)?
        var top: Fixture?
        for tier in Tier.observable {
            let fixture = try await Answers.shared.fixture(for: tier)
            let fields = fixture.result.servedFields
            if let below, tier.widens {
                let added = fields.subtracting(below.fields)
                #expect(
                    added.isEmpty == false,
                    "\(tier.rawValue) adds nothing to \(below.tier.rawValue)",
                )
                print("\(tier.rawValue) adds \(added.sorted().joined(separator: ", "))")
            }
            below = (tier, fields)
            top = fixture
        }

        let highest = try #require(top)
        #expect(
            highest.result.flagsServedFalse.isEmpty == false,
            "no flag on \(highest.tier.rawValue) reads false, so a served false was dropped",
        )
    }

    @Test("a bogon is answered without touching the network")
    func bogonNeverReachesTheNetwork() async throws {
        let refusing = RecordingTransport(key: "", inner: RefusingTransport())
        let client = clientFor(.unauth, transport: refusing)

        let result = try await client.lookup("10.0.0.1")

        #expect(result.isBogon)
        #expect(result.isVpn == false)
        #expect(isBogon("10.0.0.1"), "the standalone export must agree")
        #expect(result.isHosting == false, "a bogon answers in the widest shape")
        #expect(result.hosting?.isEmpty == true, "a bogon detail is present and empty")
        await #expect(refusing.facts.isEmpty)
    }

    @Test("a batch collapses duplicates and keeps bogons off the wire")
    func batchDedupesAndSkipsBogons() async throws {
        let transport = RecordingTransport(key: "")
        let client = clientFor(.unauth, transport: transport)

        let results = try await client.lookupBatch([probe, "8.8.8.8", probe, "10.0.0.1", "8.8.8.8"])

        #expect(results.keys == [probe, "8.8.8.8", "10.0.0.1"])
        // Distinct paths rather than a call count, so a retry against a wobbling
        // staging cannot read as a failure to deduplicate.
        let asked = Set(await transport.facts.map(\.path))
        #expect(asked == ["/\(probe)", "/8.8.8.8"])
        #expect(try results["10.0.0.1"]?.get().isBogon == true)
        for ip in [probe, "8.8.8.8"] {
            assertShape(try #require(results[ip]).get())
        }
    }
}

/// Fails every request, so "this never reached the network" is a refusal rather
/// than an absence nobody checked.
private struct RefusingTransport: ClientTransport {
    struct Reached: Error {}

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
    ) async throws -> (HTTPResponse, HTTPBody?) {
        throw Reached()
    }
}
