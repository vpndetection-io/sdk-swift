import Foundation
import HTTPTypes
import OpenAPIRuntime

@testable import VPNDetection

/// A transport that answers from a table and records what it was asked for, so
/// "never touched the network" and "kept at most N in flight" are asserted
/// rather than assumed.
final class StubTransport: ClientTransport {
    struct Route: Sendable {
        var status: Int = 200
        var body: Data?
        var headers: [String: String] = [:]

        static func json(_ object: [String: Any], status: Int = 200) -> Route {
            Route(status: status, body: try? JSONSerialization.data(withJSONObject: object))
        }
    }

    private let routes: [String: Route]
    private let delay: Duration?
    private let state = State()

    init(_ routes: [String: Route] = [:], delay: Duration? = nil) {
        self.routes = routes
        self.delay = delay
    }

    /// Successful lookups for a set of addresses, which is what most cases want.
    static func answering(_ ips: String...) -> StubTransport {
        StubTransport(answers(for: ips))
    }

    static func answers(for ips: [String]) -> [String: Route] {
        Dictionary(uniqueKeysWithValues: ips.map { ($0, .json(["ip": $0, "is_vpn": false])) })
    }

    var callCount: Int {
        get async { await state.calls.count }
    }

    var calls: [String] {
        get async { await state.calls }
    }

    var peakInFlight: Int {
        get async { await state.peak }
    }

    /// The `Authorization` header of every request, so "the key was presented"
    /// is asserted at the wire rather than assumed from the option.
    var authorizations: [String?] {
        get async { await state.authorizations }
    }

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String,
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let key = Self.key(for: request)
        await state.enter(key, authorization: request.headerFields[.authorization])
        do {
            if let delay {
                try await Task.sleep(for: delay)
            }
        } catch {
            await state.leave()
            throw error
        }

        // An unrouted address answers the way the API does, so a batch case can
        // exercise a partial failure without a second stub.
        let route = routes[key] ?? .json(["error": "not a valid IP address"], status: 400)
        var fields = HTTPFields()
        fields[.contentType] = "application/json"
        for (name, value) in route.headers {
            guard let field = HTTPField.Name(name) else {
                continue
            }
            fields[field] = value
        }
        let response = HTTPResponse(status: .init(code: route.status), headerFields: fields)
        await state.leave()
        return (response, route.body.map { HTTPBody([UInt8]($0)) })
    }

    // The lookup path is the address itself; anything else is keyed by its path
    // so the database endpoints can be routed too.
    private static func key(for request: HTTPRequest) -> String {
        let path = (request.path ?? "/").split(separator: "?", maxSplits: 1)[0]
        if path.hasPrefix("/api/") {
            return String(path)
        }
        let trimmed = String(path.dropFirst())
        return trimmed.removingPercentEncoding ?? trimmed
    }

    private actor State {
        var calls: [String] = []
        var authorizations: [String?] = []
        var peak = 0
        private var inFlight = 0

        func enter(_ key: String, authorization: String?) {
            calls.append(key)
            authorizations.append(authorization)
            inFlight += 1
            peak = max(peak, inFlight)
        }

        func leave() {
            inFlight -= 1
        }
    }
}
