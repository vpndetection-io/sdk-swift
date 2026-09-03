import Testing

@testable import VPNDetection

/// Prefix arithmetic the shared corpus cannot reach.
///
/// The corpus pins 26 addresses that sit comfortably inside or outside a range,
/// so a mask that is a bit too wide or too narrow still answers all of them
/// correctly. These are the pairs either side of a boundary, chosen to exercise
/// a prefix in the high half, one exactly at 64, and one in the low half.
@Suite("Bogon prefixes")
struct BogonTests {
    @Test(
        "an address either side of a v6 prefix boundary",
        arguments: [
            ("fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", true),  // last address of fc00::/7
            ("fe00::1", false),  // first past fc00::/7
            ("febf::1", true),  // last block of fe80::/10
            ("2001:1f::1", true),  // last block of 2001:10::/28
            ("2001:20::1", false),  // first past 2001:10::/28
            ("2001:0:a9fe::1", true),  // inside the teredo 169.254.0.0/16 wrap, /48
            ("2001:0:a9ff::1", false),  // first past it
            ("100::1", true),  // 100::/64, a prefix exactly at the halfway point
            ("100:0:0:1::1", false),  // first past 100::/64
            ("::ffff:10.0.0.1", true),  // ::ffff:0:0/96, a prefix in the low half
            ("::1:0:0:0", false),  // outside both ::/96 and ::ffff:0:0/96
        ],
    )
    func v6PrefixBoundaries(ip: String, expected: Bool) {
        #expect(isBogon(ip) == expected)
    }

    @Test("a malformed address is not a bogon rather than a crash")
    func malformedAddressesAreRejected() {
        for ip in ["", "notanip", "1.2.3", "1.2.3.4.5", "256.0.0.1", "1.2.3.-1", "::gggg", "1::2::3"] {
            #expect(isBogon(ip) == false, "\(ip)")
        }
    }
}
