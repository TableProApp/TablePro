import Foundation
@testable import TablePro

final class OfflineRegistryProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requestedURLs: [URL] = []

    static func requestCount(for url: URL) -> Int {
        lock.withLock { requestedURLs.filter { $0 == url }.count }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.withLock { Self.requestedURLs.append(url) }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"schemaVersion": 3, "retainFromPluginKit": 39, "plugins": []}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// A registry client for a view that fetches on appear. Its own URL keeps one test's requests
/// countable apart from another's, and its session never reaches the network.
@MainActor
final class OfflineRegistry {
    let client: RegistryClient
    let manifestURL: URL

    init() throws {
        guard let manifestURL = URL(string: "https://registry.invalid/\(UUID().uuidString)/plugins/v3.json") else {
            throw URLError(.badURL)
        }
        self.manifestURL = manifestURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineRegistryProtocol.self]
        client = RegistryClient(manifestURL: manifestURL, session: URLSession(configuration: configuration))
    }

    var requestCount: Int {
        OfflineRegistryProtocol.requestCount(for: manifestURL)
    }

    /// Waits out a fetch the Plugins pane started on appear.
    func settle() async {
        await client.fetch(policy: .ifStale)
    }
}
