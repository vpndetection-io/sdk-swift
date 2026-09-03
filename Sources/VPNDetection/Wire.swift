import AsyncHTTPClient
import Foundation
import HTTPTypes
import OpenAPIAsyncHTTPClient
import OpenAPIRuntime

/// The transport used when ``VPNDetectionClient/Options/transport`` is left unset.
///
/// One `HTTPClient` for the whole process, held in a global so it is never
/// deallocated. That matters: AsyncHTTPClient's `deinit` traps in debug builds
/// when a client was not shut down, and an SDK whose first README line is
/// `VPNDetectionClient()` must not impose a shutdown contract on its caller.
/// This is the model `HTTPClient.shared` already uses, with one difference that
/// is the whole reason we do not simply use it: **redirects are refused**.
///
/// The download endpoint answers `302` to object storage, and a transport that
/// follows the redirect reads a dataset that routinely runs to gigabytes into
/// memory. `.disallow` is one value rather than a delegate to get right, and it
/// behaves identically on Linux and on Apple platforms.
enum DefaultTransport {
    static let shared: any ClientTransport = AsyncHTTPClientTransport(
        configuration: .init(client: httpClient),
    )

    private static let httpClient = HTTPClient(
        eventLoopGroupProvider: .singleton,
        configuration: HTTPClient.Configuration(redirectConfiguration: .disallow),
    )
}

/// Turns every non-2xx answer into a ``VPNDetectionError`` before the generated
/// client can decode it.
///
/// Classifying here rather than over the generated per-status output cases is
/// what makes the range rule enforceable: a status this API does not document
/// today, such as a 404 from a bad dataset id, arrives with its real number
/// rather than as an `undocumented` case that has to be re-derived.
struct ErrorMiddleware: ClientMiddleware {
    // Enough for an error envelope from the API or from an intermediary, and
    // small enough that a runaway body cannot be used to exhaust memory.
    private static let maxErrorBodyBytes = 64 * 1024

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?),
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let (response, responseBody) = try await next(request, body, baseURL)
        let status = response.status.code

        // A success here means the transport followed the 302 and is holding the
        // dataset itself. Refused before the body is touched, which is what
        // stops a caller-supplied transport from streaming gigabytes into RAM.
        if operationID == "downloadDatabase", (200..<300).contains(status) {
            throw VPNDetectionError(
                kind: .serverError,
                message: "the download endpoint answered \(status) rather than a redirect, which"
                    + " means the transport followed it; supply a transport that does not",
                status: Int(status),
            )
        }
        guard status >= 400 else {
            return (response, responseBody)
        }
        let collected = try? await ArraySlice(
            collecting: responseBody ?? HTTPBody(), upTo: Self.maxErrorBodyBytes,
        )
        throw VPNDetectionError.from(
            status: Int(status), headers: response.headerFields, body: collected ?? [],
        )
    }
}

/// Presents the API key.
///
/// `Authorization: Bearer` of the three schemes the API accepts, because the
/// other two put the key in a query string where it lands in access logs.
struct AuthMiddleware: ClientMiddleware {
    let apiKey: String

    func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?),
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        request.headerFields[.authorization] = "Bearer \(apiKey)"
        return try await next(request, body, baseURL)
    }
}

/// Runs an operation, retrying only what is worth retrying.
///
/// A `429` carrying `Retry-After` is a transient rate limit and the header is
/// the wait; a `429` without one is a spent allowance, and retrying it hammers a
/// quota that will not recover until its window rolls over. Everything else in
/// the 4xx range is a client error and is never retried.
func withRetry<T>(_ retries: Int, _ operation: () async throws -> T) async throws -> T {
    var attempt = 0
    while true {
        do {
            return try await operation()
        } catch {
            let failure = VPNDetectionError.wrapping(error)
            guard attempt < retries, failure.isRetryable else {
                throw failure
            }
            try await Task.sleep(for: failure.retryAfter ?? backoff(attempt))
            attempt += 1
        }
    }
}

private func backoff(_ attempt: Int) -> Duration {
    .milliseconds(min(5_000, 200 << min(attempt, 5)))
}
