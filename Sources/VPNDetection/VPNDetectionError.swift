import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Every failure the library reports.
///
/// `retryAfter` is set only for ``VPNDetectionErrorKind/rateLimited``, and it is
/// the wait the API asked for rather than one the library invented.
public struct VPNDetectionError: Error, Sendable, Hashable {
    public let kind: VPNDetectionErrorKind
    public let message: String
    /// The HTTP status, or `nil` when the request never got an answer.
    public let status: Int?
    /// The server-supplied wait, taken from `Retry-After`.
    public let retryAfter: Duration?

    /// Whether retrying this exact request could succeed.
    public var isRetryable: Bool {
        kind == .rateLimited || kind == .serverError || kind == .network
    }

    public init(
        kind: VPNDetectionErrorKind, message: String,
        status: Int? = nil, retryAfter: Duration? = nil,
    ) {
        self.kind = kind
        self.message = message
        self.status = status
        self.retryAfter = retryAfter
    }
}

/// Why a request failed.
///
/// ``rateLimited`` and ``quotaExceeded`` both arrive as HTTP 429 and are NOT the
/// same thing. A rate limit is the API protecting itself and carries
/// `Retry-After`; retrying works. A spent quota carries no such header and
/// retrying will not help until the window rolls over or the limit is raised.
/// The header is the only thing that distinguishes them.
public enum VPNDetectionErrorKind: String, Sendable, Hashable, CaseIterable {
    case badRequest = "bad_request"
    case unauthorized = "unauthorized"
    case forbidden = "forbidden"
    case rateLimited = "rate_limited"
    case quotaExceeded = "quota_exceeded"
    case serverError = "server_error"
    case network = "network"
}

extension VPNDetectionError: CustomStringConvertible {
    public var description: String {
        status.map { "\(kind.rawValue) (HTTP \($0)): \(message)" } ?? "\(kind.rawValue): \(message)"
    }
}

extension VPNDetectionError: LocalizedError {
    public var errorDescription: String? { description }
}

extension VPNDetectionError {
    /// Classifies a non-2xx answer.
    ///
    /// The decision is made on the STATUS RANGE, never on an enumerated list of
    /// the statuses this API happens to document today. Mapping 400/401/403/429
    /// and letting the rest fall through to the `serverError` default is the
    /// easy mistake, and it makes a 404 from a bad dataset id retryable.
    ///
    /// - Parameter fallback: What to say when the answer carried no envelope,
    ///   for a caller such as object storage whose failures never do.
    static func from(
        status: Int, headers: HTTPFields, body: ArraySlice<UInt8>, fallback: String? = nil,
    ) -> VPNDetectionError {
        let message = messageOf(body) ?? fallback ?? "request failed with status \(status)"
        let retryAfter = parseRetryAfter(headers[.retryAfter])

        if status == 429 {
            // Present means transient, absent means an allowance is spent.
            // Nothing else in the response separates the two.
            guard let retryAfter else {
                return VPNDetectionError(kind: .quotaExceeded, message: message, status: status)
            }
            return VPNDetectionError(
                kind: .rateLimited, message: message, status: status, retryAfter: retryAfter,
            )
        }
        if status >= 500 {
            return VPNDetectionError(kind: .serverError, message: message, status: status)
        }
        switch status {
        case 401: return VPNDetectionError(kind: .unauthorized, message: message, status: status)
        case 403: return VPNDetectionError(kind: .forbidden, message: message, status: status)
        default: return VPNDetectionError(kind: .badRequest, message: message, status: status)
        }
    }

    /// Reduces anything thrown beneath the idiomatic layer to one error type.
    ///
    /// The generated client wraps whatever the transport or a middleware threw
    /// in `ClientError`, so the error this library raised has to be dug back out
    /// of `underlyingError` before it can be classified.
    static func wrapping(_ error: any Error) -> VPNDetectionError {
        if let ours = error as? VPNDetectionError {
            return ours
        }
        if let client = error as? ClientError {
            return wrapping(client.underlyingError)
        }
        return VPNDetectionError(kind: .network, message: "\(error)")
    }
}

// The two APIs behind this host answer with different envelopes: the lookup
// endpoint uses `error`, the database endpoints use `rc`. Both are read here so
// a caller never has to know which one they hit.
private func messageOf(_ body: ArraySlice<UInt8>) -> String? {
    guard !body.isEmpty,
        let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: Data(body))
    else {
        return nil
    }
    return envelope.error ?? envelope.rc
}

private struct ErrorEnvelope: Decodable {
    let error: String?
    let rc: String?
}

// The header is documented as an integer count of seconds, but RFC 9110 also
// permits an HTTP date and an intermediary may send one, so both are read.
private func parseRetryAfter(_ value: String?) -> Duration? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else {
        return nil
    }
    if let seconds = Int(trimmed), seconds >= 0 {
        return .seconds(seconds)
    }
    guard let when = httpDateFormatter.date(from: trimmed) else {
        return nil
    }
    return .seconds(max(0, Int(when.timeIntervalSinceNow.rounded(.up))))
}

private let httpDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter
}()
