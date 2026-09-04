import Foundation
import Testing

/// Which plan tiers a run can observe, and the secret each one needs.
///
/// A tier is observable only when its secret holds something NON-EMPTY. CI
/// interpolates a secret that does not exist to an empty string rather than
/// leaving the variable unset, and a client built with an empty key presents no
/// credential at all, so an empty secret would quietly run as a second
/// unauthenticated rung and make every comparison against it vacuously true.
enum Tier: String, CaseIterable, Sendable {
    case unauth
    case free
    case starter
    case scale
    case max

    /// The plan tier comes from the ORG rather than from the key, so each rung
    /// needs its own organization and therefore its own secret.
    var secret: String? {
        switch self {
        case .unauth: nil
        case .free: "VPNDETECTION_STAGING_KEY_FREE"
        case .starter: "VPNDETECTION_STAGING_KEY_STARTER"
        case .scale: "VPNDETECTION_STAGING_KEY_SCALE"
        case .max: "VPNDETECTION_STAGING_KEY_MAX"
        }
    }

    /// What this rung promises against whichever observable rung sits below it.
    /// A paid tier serves strictly more; a free key and no key at all are one
    /// entitlement reached two ways.
    var widens: Bool {
        switch self {
        case .unauth, .free: false
        case .starter, .scale, .max: true
        }
    }

    var key: String {
        guard let secret else {
            return ""
        }
        return (ProcessInfo.processInfo.environment[secret] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Why this rung cannot be exercised, or `nil` when it can.
    var skipReason: String? {
        guard let secret, key.isEmpty else {
            return nil
        }
        return "\(secret) is not set, so the \(rawValue) tier cannot be exercised"
    }

    /// The trait that skips a tier's tests, naming the secret, rather than
    /// failing a run that was never given the credential.
    var needsKey: ConditionTrait {
        .enabled(if: skipReason == nil, Comment(rawValue: skipReason ?? "the key is present"))
    }

    static var observable: [Tier] {
        allCases.filter { $0.skipReason == nil }
    }
}
