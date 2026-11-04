import Foundation
@testable import TablePro

final class OfflineRegistryProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requestedURLs: [URL] = []
    static let manifest = Data(#"{"schemaVersion": 3, "serial": 1, "retainFromPluginKit": 39, "plugins": []}"#.utf8)

    static func requestCount(for url: URL) -> Int {
        lock.withLock { requestedURLs.filter { $0 == url }.count }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    private static func body(for url: URL) -> Data? {
        guard url.pathExtension == "sig" else { return manifest }
        return try? SignedRegistryManifest.signature(of: manifest)
    }

    override func startLoading() {
        guard let url = request.url,
              let body = Self.body(for: url),
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
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

// A registry client for a view that fetches on appear. Its own URL keeps one test's requests countable
// apart from another's, its session never reaches the network, and its signed manifest verifies.
@MainActor
final class OfflineRegistry {
    let client: RegistryClient
    let manifestURL: URL
    private let defaults: EphemeralDefaults

    init() throws {
        guard let manifestURL = URL(string: "https://registry.invalid/\(UUID().uuidString)/plugins/v3.json") else {
            throw URLError(.badURL)
        }
        self.manifestURL = manifestURL
        defaults = try EphemeralDefaults()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineRegistryProtocol.self]
        client = SignedRegistryManifest.client(
            manifestURL: manifestURL,
            session: URLSession(configuration: configuration),
            defaults: defaults.defaults
        )
    }

    var requestCount: Int {
        OfflineRegistryProtocol.requestCount(for: manifestURL)
    }

    // Waits out a fetch the Plugins pane started on appear.
    func settle() async {
        await client.fetch(policy: .ifStale)
    }
}
