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
        client?.urlProtocol(self, didLoad: Data(#"{"schemaVersion": 2, "plugins": []}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// A registry client for a view that fetches on appear. Its own URL, defaults and cache file keep one
/// test's requests countable apart from another's, and its session never reaches the network.
@MainActor
final class OfflineRegistry {
    let client: RegistryClient
    let manifestURL: URL
    private let defaults: EphemeralDefaults
    private let directory: URL

    init() throws {
        guard let manifestURL = URL(string: "https://registry.invalid/\(UUID().uuidString)/plugins.json") else {
            throw URLError(.badURL)
        }
        self.manifestURL = manifestURL
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfflineRegistry-\(UUID().uuidString)", isDirectory: true)
        defaults = try EphemeralDefaults()
        defaults.defaults.set(manifestURL.absoluteString, forKey: RegistryClient.customRegistryURLKey)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineRegistryProtocol.self]
        client = RegistryClient(
            userDefaults: defaults.defaults,
            session: URLSession(configuration: configuration),
            manifestCacheURL: directory.appendingPathComponent("registry-manifest.json")
        )
    }

    var requestCount: Int {
        OfflineRegistryProtocol.requestCount(for: manifestURL)
    }

    /// A Plugins pane's fetch writes defaults and the cache file when it lands, and a write after
    /// deinit recreates both directories. A fresh manifest also makes a fetch still queued a no-op.
    func settle() async {
        await client.ensureManifest(.ifStale)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}
