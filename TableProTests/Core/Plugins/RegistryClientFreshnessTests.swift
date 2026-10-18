import Foundation
@testable import TablePro
import Testing

private final class MockRegistryProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queue: [(status: Int, body: Data)] = []
    nonisolated(unsafe) private static var received: [URLRequest] = []

    static func reset(responses: [(status: Int, body: Data)]) {
        lock.lock(); defer { lock.unlock() }
        queue = responses
        received = []
    }

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return received.count
    }

    private static func next(recording request: URLRequest) -> (status: Int, body: Data) {
        lock.lock(); defer { lock.unlock() }
        received.append(request)
        return queue.isEmpty ? (200, Data()) : queue.removeFirst()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let response = Self.next(recording: request)
        guard let url = request.url,
              let httpResponse = HTTPURLResponse(
                  url: url, statusCode: response.status, httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              )
        else { return }
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("RegistryClient freshness", .serialized)
@MainActor
struct RegistryClientFreshnessTests {
    private let suite: EphemeralDefaults

    init() throws {
        suite = try EphemeralDefaults()
    }

    private static let testTypeId = "TestFreshnessDB"

    private func manifestURL() throws -> URL {
        try #require(URL(string: "https://registry.invalid/\(UUID().uuidString)/plugins/v3.json"))
    }

    private func manifestData(includingTestPlugin: Bool, schemaVersion: Int = 3) -> Data {
        var plugins = ""
        if includingTestPlugin {
            let kit = PluginManager.currentPluginKitVersion + 1
            plugins = """
            {
                "id": "com.test.freshness-driver",
                "name": "Freshness Test Driver",
                "databaseTypeIds": ["\(Self.testTypeId)"],
                "releases": [{
                    "version": "0.82.0", "build": 820099, "channel": "stable", "pluginKit": \(kit),
                    "minimumSystemVersion": "13.0", "url": "https://x", "sha256": "deadbeef"
                }]
            }
            """
        }
        return Data("{\"schemaVersion\": \(schemaVersion), \"retainFromPluginKit\": 39, \"plugins\": [\(plugins)]}".utf8)
    }

    private func makeEnvironment(
        cachedManifest: Data? = nil
    ) throws -> (client: RegistryClient, defaults: UserDefaults, tempDir: URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("registry-freshness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let url = try manifestURL()
        let cache = URLCache(memoryCapacity: 4_000_000, diskCapacity: 0, directory: nil)
        if let cachedManifest {
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ))
            cache.storeCachedResponse(CachedURLResponse(response: response, data: cachedManifest), for: URLRequest(url: url))
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockRegistryProtocol.self]
        config.urlCache = cache
        let client = RegistryClient(manifestURL: url, session: URLSession(configuration: config))
        return (client, suite.defaults, tempDir)
    }

    @Test("The client asks for the manifest at the URL it was given")
    func requestsTheInjectedURL() throws {
        let (client, _, _) = try makeEnvironment()

        #expect(client.makeRequest(policy: .ifStale).url == client.manifestURL)
        #expect(client.manifestURL.host() == "registry.invalid")
    }

    @Test("The shipped client reads the v3 manifest from updates.tablepro.app with a 20 MB disk cache")
    func defaultManifestURLAndSession() {
        let config = RegistryClient.makeDefaultSession().configuration

        #expect(RegistryClient.defaultManifestURL.absoluteString == "https://updates.tablepro.app/plugins/v3.json")
        #expect(config.timeoutIntervalForRequest == 15)
        #expect((config.urlCache?.diskCapacity ?? 0) >= 20_000_000)
    }

    @Test("ifStale lets the HTTP cache answer, mustBeCurrent revalidates with the origin")
    func cachePolicies() throws {
        let (client, _, _) = try makeEnvironment()

        #expect(client.makeRequest(policy: .ifStale).cachePolicy == .useProtocolCachePolicy)
        #expect(client.makeRequest(policy: .mustBeCurrent).cachePolicy == .reloadRevalidatingCacheData)
    }

    @Test("A cached v3 response is decoded when the client starts")
    func cachedManifestDecodedAtInit() throws {
        let (client, _, _) = try makeEnvironment(cachedManifest: manifestData(includingTestPlugin: true))

        #expect(client.manifest?.plugins.map(\.id) == ["com.test.freshness-driver"])
        #expect(!client.isManifestCurrent)
    }

    @Test("A cached v2 response is ignored")
    func cachedSchemaTwoIgnored() throws {
        let (client, _, _) = try makeEnvironment(
            cachedManifest: manifestData(includingTestPlugin: false, schemaVersion: 2)
        )

        #expect(client.manifest == nil)
    }

    @Test("concurrent callers share one in-flight fetch")
    func concurrentCallersShareOneFetch() async throws {
        MockRegistryProtocol.reset(responses: [
            (200, manifestData(includingTestPlugin: false)),
            (200, manifestData(includingTestPlugin: false))
        ])
        let (client, _, _) = try makeEnvironment()

        async let first: Void = client.fetch(policy: .ifStale)
        async let second: Void = client.fetch(policy: .ifStale)
        _ = await (first, second)

        #expect(MockRegistryProtocol.requestCount == 1)
        #expect(client.isManifestCurrent)
    }

    @Test("mustBeCurrent fetches again after an ifStale fetch and replaces the manifest")
    func mustBeCurrentFetchesAgain() async throws {
        MockRegistryProtocol.reset(responses: [
            (200, manifestData(includingTestPlugin: false)),
            (200, manifestData(includingTestPlugin: true))
        ])
        let (client, _, _) = try makeEnvironment()

        await client.fetch(policy: .ifStale)
        #expect(client.manifest?.plugins.isEmpty == true)

        await client.fetch(policy: .mustBeCurrent)
        #expect(MockRegistryProtocol.requestCount == 2)
        #expect(client.manifest?.plugins.count == 1)
    }

    @Test("A failed refresh keeps the cached manifest and is not current")
    func failedRefreshKeepsCachedManifest() async throws {
        MockRegistryProtocol.reset(responses: [(500, Data())])
        let (client, _, _) = try makeEnvironment(cachedManifest: manifestData(includingTestPlugin: true))

        await client.fetch(policy: .mustBeCurrent)

        #expect(client.manifest?.plugins.count == 1)
        #expect(!client.isManifestCurrent)
    }

    @Test("A v2 document from the server is refused and the cached manifest stays")
    func fetchedSchemaTwoRefused() async throws {
        MockRegistryProtocol.reset(responses: [(200, manifestData(includingTestPlugin: false, schemaVersion: 2))])
        let (client, _, _) = try makeEnvironment(cachedManifest: manifestData(includingTestPlugin: true))

        await client.fetch(policy: .mustBeCurrent)

        #expect(client.manifest?.plugins.count == 1)
        #expect(!client.isManifestCurrent)
    }

    @Test("stale manifest miss triggers a fresh lookup before reporting not found")
    func staleManifestMissRevalidatesBeforeNotFound() async throws {
        let stale = manifestData(includingTestPlugin: false)
        let fresh = manifestData(includingTestPlugin: true)
        MockRegistryProtocol.reset(responses: [(200, stale), (200, fresh)])
        let (client, defaults, tempDir) = try makeEnvironment(cachedManifest: stale)

        let manager = PluginManager(
            userDefaults: defaults,
            builtInPluginsURL: nil,
            userPluginsDir: tempDir.appendingPathComponent("Plugins", isDirectory: true)
        )

        do {
            try await manager.installMissingPlugin(
                for: DatabaseType(rawValue: Self.testTypeId),
                registryClient: client
            ) { _ in }
            Issue.record("Expected install to fail at compatibility validation")
        } catch let error as PluginError {
            #expect(MockRegistryProtocol.requestCount == 2)
            if case .notFound = error {
                Issue.record("Lookup missed a plugin the forced revalidation should have found")
            }
            guard case .appTooOldForPlugin = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
    }

    @Test("unreachable registry reports a connection problem, not a missing plugin")
    func unreachableRegistryReportsConnectionProblem() async throws {
        MockRegistryProtocol.reset(responses: [(500, Data()), (500, Data())])
        let (client, defaults, tempDir) = try makeEnvironment()

        let manager = PluginManager(
            userDefaults: defaults,
            builtInPluginsURL: nil,
            userPluginsDir: tempDir.appendingPathComponent("Plugins", isDirectory: true)
        )

        do {
            try await manager.installMissingPlugin(
                for: DatabaseType(rawValue: Self.testTypeId),
                registryClient: client
            ) { _ in }
            Issue.record("Expected install to fail")
        } catch let error as PluginError {
            guard case .registryUnreachable = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
    }

    @Test("an offered export format is found in the registry by its plugin id")
    func exportFormatResolvesByRegistryId() async throws {
        let fresh = manifestData(includingTestPlugin: true)
        MockRegistryProtocol.reset(responses: [(200, fresh)])
        let (client, defaults, tempDir) = try makeEnvironment()
        let manager = PluginManager(
            userDefaults: defaults,
            builtInPluginsURL: nil,
            userPluginsDir: tempDir.appendingPathComponent("Plugins", isDirectory: true)
        )
        let format = InstallableExportFormat(
            formatId: "freshness",
            displayName: "Freshness",
            registryPluginId: "com.test.freshness-driver"
        )

        do {
            try await manager.installMissingExportFormat(format, registryClient: client) { _ in }
            Issue.record("Expected install to fail at compatibility validation")
        } catch let error as PluginError {
            guard case .appTooOldForPlugin = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
    }

    @Test("an offered export format missing from the registry reports not found")
    func exportFormatMissingFromRegistry() async throws {
        let empty = manifestData(includingTestPlugin: false)
        MockRegistryProtocol.reset(responses: [(200, empty), (200, empty)])
        let (client, defaults, tempDir) = try makeEnvironment()
        let manager = PluginManager(
            userDefaults: defaults,
            builtInPluginsURL: nil,
            userPluginsDir: tempDir.appendingPathComponent("Plugins", isDirectory: true)
        )
        let format = InstallableExportFormat(
            formatId: "freshness",
            displayName: "Freshness",
            registryPluginId: "com.test.freshness-driver"
        )

        do {
            try await manager.installMissingExportFormat(format, registryClient: client) { _ in }
            Issue.record("Expected install to fail")
        } catch let error as PluginError {
            guard case .notFound = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
    }

    @Test("registryPlugin resolves by database type id")
    func registryPluginLookup() throws {
        let manifest = try JSONDecoder().decode(RegistryManifest.self, from: manifestData(includingTestPlugin: true))
        #expect(PluginManager.registryPlugin(forTypeId: Self.testTypeId, in: manifest) != nil)
        #expect(PluginManager.registryPlugin(forTypeId: "SomethingElse", in: manifest) == nil)
        #expect(PluginManager.registryPlugin(forTypeId: Self.testTypeId, in: nil) == nil)
    }
}
