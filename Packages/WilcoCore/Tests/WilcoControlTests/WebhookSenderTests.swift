import Foundation
import Synchronization
import Testing
@testable import WilcoControl

/// Answers requests without a network: `/redirect` bounces to another host,
/// anything else answers 200 and tries to set a cookie.
private final class StubServer: URLProtocol, @unchecked Sendable {
    static let seen = Mutex<[URL]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        Self.seen.withLock { $0.append(url) }
        if url.path == "/redirect" {
            let target = URL(string: "http://elsewhere.example/collect")!
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            // If the session follows, it stops this load and starts one for
            // `target`, which `seen` records. If it refuses, the 302 is the answer.
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Set-Cookie": "track=1; Path=/"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("ok".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("Webhook sender", .serialized)
struct WebhookSenderTests {
    private let sender = WebhookSender { $0.protocolClasses = [StubServer.self] }

    private func post(_ url: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.httpBody = Data("heard on comms".utf8)
        return request
    }

    @Test func reportsTheStatus() async throws {
        #expect(try await sender.send(post("http://console.test/cue")) == 200)
    }

    /// A redirect would carry what was heard to a host the rule never named.
    @Test func neverFollowsARedirect() async throws {
        StubServer.seen.withLock { $0.removeAll() }
        let status = try await sender.send(post("http://console.test/redirect"))
        #expect(status == 302)
        #expect(StubServer.seen.withLock { $0.map(\.host) } == ["console.test"])
    }

    @Test func keepsNoCookiesBetweenRequests() async throws {
        _ = try await sender.send(post("http://console.test/cue"))
        #expect(HTTPCookieStorage.shared.cookies(for: URL(string: "http://console.test/cue")!)?.isEmpty ?? true)
    }
}
