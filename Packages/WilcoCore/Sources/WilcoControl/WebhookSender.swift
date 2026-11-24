import Foundation

/// Sends webhook requests and reports the status code.
///
/// The session keeps nothing between requests (no cookies, cache or stored
/// credentials) and never follows a redirect: the request goes to the host
/// written in the rule or nowhere, so a server can't bounce what was heard
/// on comms to a third party. Only the response's status is read; its body
/// is never downloaded, so a server can't fill memory with a huge reply.
public final class WebhookSender: Sendable {
    private let session: URLSession

    /// `configure` adjusts the session before it is built (tests add a stub
    /// protocol).
    public init(configure: (URLSessionConfiguration) -> Void = { _ in }) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        configuration.waitsForConnectivity = false
        configure(configuration)
        session = URLSession(configuration: configuration)
    }

    /// The HTTP status the server answered with. A redirect is returned as
    /// its own 3xx status, not followed.
    public func send(_ request: URLRequest) async throws -> Int {
        let (bytes, response) = try await session.bytes(for: request, delegate: NoRedirects())
        bytes.task.cancel()
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            nil
        }
    }
}
