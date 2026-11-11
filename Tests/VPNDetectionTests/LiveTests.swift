import Foundation
import Testing

@testable import VPNDetection

/// Real requests against production, skipped unless `VPNDETECTION_LIVE=1` so the
/// ordinary suite stays offline and costs no quota.
///
///     VPNDETECTION_LIVE=1 ./scripts/test.sh --filter Live
@Suite("Live", .enabled(if: ProcessInfo.processInfo.environment["VPNDETECTION_LIVE"] == "1"))
struct LiveTests {
    @Test("a lookup without a key leaves out what a key adds")
    func keylessLookup() async throws {
        let client = VPNDetectionClient()

        let vpn = try await client.lookup("45.83.91.1")
        #expect(vpn.ip == "45.83.91.1")
        #expect(vpn.isVpn)
        #expect(vpn.isBogon == false)

        let notVpn = try await client.lookup("1.1.1.1")
        #expect(notVpn.isVpn == false)
        // The assertion a stub cannot make honestly: without a key the members a
        // key adds are ABSENT, which is different from a served false.
        #expect(notVpn.isHosting == nil)
        #expect(notVpn.isResproxy == nil)
        #expect(notVpn.vpn == nil)
    }

    @Test("a bogon is answered without a request")
    func bogonCostsNothing() async throws {
        let result = try await VPNDetectionClient().lookup("192.168.1.1")

        #expect(result.isBogon)
        #expect(result.isVpn == false)
        #expect(result.isHosting == false, "a local answer is the widest shape")
    }

    @Test("a batch without a key is refused, and its bogon still answered")
    func batchOverProduction() async throws {
        let client = VPNDetectionClient()

        let results = try await client.lookupBatch(
            ["45.83.91.1", "1.1.1.1", "45.83.91.1", "10.0.0.1"],
        )

        #expect(results.keys == ["45.83.91.1", "1.1.1.1", "10.0.0.1"])
        #expect(try results["10.0.0.1"]?.get().isBogon == true)
        for ip in ["45.83.91.1", "1.1.1.1"] {
            guard case .failure(let error) = try #require(results[ip]) else {
                Issue.record("a batch without a key answered \(ip)")
                continue
            }
            #expect(error.kind == .unauthorized)
            #expect(error.status == 401)
        }
    }
}
