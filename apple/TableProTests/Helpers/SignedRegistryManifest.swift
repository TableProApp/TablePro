import CryptoKit
import Foundation
@testable import TablePro

// A key made for this test run, so a test never needs the app's real signing key.
enum SignedRegistryManifest {
    static let key = Curve25519.Signing.PrivateKey()

    static func signature(of body: Data, by key: Curve25519.Signing.PrivateKey = key) throws -> Data {
        Data((try key.signature(for: body).base64EncodedString() + "\n").utf8)
    }

    static func signatureURL(for manifestURL: URL) -> URL {
        RegistryClient.signatureURL(for: manifestURL)
    }

    static func manifest(serial: Int? = 1, plugins: [String] = []) -> Data {
        let serialEntry = serial.map { "\"serial\": \($0), " } ?? ""
        return Data(
            "{\"schemaVersion\": 3, \(serialEntry)\"retainFromPluginKit\": 39, \"plugins\": [\(plugins.joined(separator: ","))]}"
                .utf8
        )
    }

    @MainActor
    static func client(manifestURL: URL, session: URLSession, defaults: UserDefaults) -> RegistryClient {
        RegistryClient(manifestURL: manifestURL, session: session, publicKey: key.publicKey, defaults: defaults)
    }
}

// Answers each URL from its own queue, so a manifest and its signature are served apart. A query, such as the
// client's CDN cache buster, does not change the queue. An unqueued request gets 404.
final class RegistryStubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queues: [URL: [(status: Int, body: Data)]] = [:]
    nonisolated(unsafe) private static var received: [URL] = []

    private static func queueKey(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.query = nil
        return components.url ?? url
    }

    static func enqueue(_ responses: [(status: Int, body: Data)], at url: URL) {
        lock.withLock { queues[queueKey(url), default: []].append(contentsOf: responses) }
    }

    // A signed copy of each 200 body at the manifest URL, and a 404 signature for any other status.
    static func enqueueSigned(_ responses: [(status: Int, body: Data)], at manifestURL: URL) throws {
        enqueue(responses, at: manifestURL)
        let signatures = try responses.map { response -> (status: Int, body: Data) in
            guard response.status == 200 else { return (404, Data()) }
            return (200, try SignedRegistryManifest.signature(of: response.body))
        }
        enqueue(signatures, at: SignedRegistryManifest.signatureURL(for: manifestURL))
    }

    static func requestedURLs(for url: URL) -> [URL] {
        lock.withLock { received.filter { queueKey($0) == queueKey(url) } }
    }

    static func requestCount(for url: URL) -> Int {
        requestedURLs(for: url).count
    }

    private static func next(for url: URL) -> (status: Int, body: Data) {
        lock.withLock {
            received.append(url)
            let key = queueKey(url)
            guard var queue = queues[key], !queue.isEmpty else { return (404, Data()) }
            let response = queue.removeFirst()
            queues[key] = queue
            return response
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = Self.next(for: url)
        guard let httpResponse = HTTPURLResponse(
            url: url, statusCode: response.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
