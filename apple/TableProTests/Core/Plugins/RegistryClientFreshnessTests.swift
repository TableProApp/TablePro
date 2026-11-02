import Foundation
@testable import TablePro
import Testing

@Suite("RegistryClient freshness", .serialized)
@MainActor
struct RegistryClientFreshnessTests {
    private static let testTypeId = "TestFreshnessDB"
    private let registryDefaults: EphemeralDefaults

    init() throws {
        registryDefaults = try EphemeralDefaults()
    }

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
                "exportFormatIds": [],
                "releases": [{
                    "version": "0.82.0", "build": 820099, "channel": "stable", "pluginKit": \(kit),
                    "minimumSystemVersion": "13.0", "url": "https://x", "sha256": "deadbeef"
                }]
            }
            """
        }
        let body = "{\"schemaVersion\": \(schemaVersion), \"serial\": 1, \"retainFromPluginKit\": 39, \"plugins\": [\(plugins)]}"
        return Data(body.utf8)
    }

    private func store(_ data: Data, at url: URL, in cache: URLCache) throws {
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        cache.storeCachedResponse(CachedURLResponse(response: response, data: data), for: URLRequest(url: url))
    }

    // Each 200 response is served with its signature beside it.
    private func makeEnvironment(
        cachedManifest: Data? = nil,
        serving responses: [(status: Int, body: Data)] = []
    ) throws -> (client: RegistryClient, tempDir: URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("registry-freshness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let url = try manifestURL()
        try RegistryStubProtocol.enqueueSigned(responses, at: url)
        let cache = URLCache(memoryCapacity: 4_000_000, diskCapacity: 0, directory: nil)
        if let cachedManifest {
            try store(cachedManifest, at: url, in: cache)
            try store(
                SignedRegistryManifest.signature(of: cachedManifest),
                at: SignedRegistryManifest.signatureURL(for: url),
                in: cache
            )
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RegistryStubProtocol.self]
        config.urlCache = cache
        let client = SignedRegistryManifest.client(
            manifestURL: url,
            session: URLSession(configuration: config),
            defaults: registryDefaults.defaults
        )
        return (client, tempDir)
    }

    private func requestCount(_ client: RegistryClient) -> Int {
        RegistryStubProtocol.requestCount(for: client.manifestURL)
    }

    @Test("The client asks for the manifest at the URL it was given")
    func requestsTheInjectedURL() throws {
        let (client, _) = try makeEnvironment()

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
        let (client, _) = try makeEnvironment()

        #expect(client.makeRequest(policy: .ifStale).cachePolicy == .useProtocolCachePolicy)
        #expect(client.makeRequest(policy: .mustBeCurrent).cachePolicy == .reloadRevalidatingCacheData)
    }

    @Test("A cached v3 response is decoded when the client starts")
    func cachedManifestDecodedAtInit() throws {
        let (client, _) = try makeEnvironment(cachedManifest: manifestData(includingTestPlugin: true))

        #expect(client.manifest?.plugins.map(\.id) == ["com.test.freshness-driver"])
        #expect(!client.isManifestCurrent)
    }

    @Test("A cached v2 response is ignored")
    func cachedSchemaTwoIgnored() throws {
        let (client, _) = try makeEnvironment(
            cachedManifest: manifestData(includingTestPlugin: false, schemaVersion: 2)
        )

        #expect(client.manifest == nil)
    }

    @Test("concurrent callers share one in-flight fetch")
    func concurrentCallersShareOneFetch() async throws {
        let (client, _) = try makeEnvironment(serving: [
            (200, manifestData(includingTestPlugin: false)),
            (200, manifestData(includingTestPlugin: false))
        ])

        async let first = client.fetch(policy: .ifStale)
        async let second = client.fetch(policy: .ifStale)
        let (firstResult, secondResult) = await (first, second)

        #expect(requestCount(client) == 1)
        #expect(client.isManifestCurrent)
        #expect(firstResult != nil && secondResult != nil)
    }

    @Test("mustBeCurrent fetches again after an ifStale fetch and replaces the manifest")
    func mustBeCurrentFetchesAgain() async throws {
        let (client, _) = try makeEnvironment(serving: [
            (200, manifestData(includingTestPlugin: false)),
            (200, manifestData(includingTestPlugin: true))
        ])

        await client.fetch(policy: .ifStale)
        #expect(client.manifest?.plugins.isEmpty == true)

        await client.fetch(policy: .mustBeCurrent)
        #expect(requestCount(client) == 2)
        #expect(client.manifest?.plugins.count == 1)
    }

    @Test("A failed refresh keeps the cached manifest and is not current")
    func failedRefreshKeepsCachedManifest() async throws {
        let (client, _) = try makeEnvironment(
            cachedManifest: manifestData(includingTestPlugin: true),
            serving: [(500, Data())]
        )

        let result = await client.fetch(policy: .mustBeCurrent)

        #expect(result == nil)
        #expect(client.manifest?.plugins.count == 1)
        #expect(!client.isManifestCurrent)
    }

    @Test("A v2 document from the server is refused and the cached manifest stays")
    func fetchedSchemaTwoRefused() async throws {
        let (client, _) = try makeEnvironment(
            cachedManifest: manifestData(includingTestPlugin: true),
            serving: [(200, manifestData(includingTestPlugin: false, schemaVersion: 2))]
        )

        await client.fetch(policy: .mustBeCurrent)

        #expect(client.manifest?.plugins.count == 1)
        #expect(!client.isManifestCurrent)
    }

    @Test("stale manifest miss triggers a fresh lookup before reporting not found")
    func staleManifestMissRevalidatesBeforeNotFound() async throws {
        let stale = manifestData(includingTestPlugin: false)
        let fresh = manifestData(includingTestPlugin: true)
        let (client, tempDir) = try makeEnvironment(cachedManifest: stale, serving: [(200, stale), (200, fresh)])

        let manager = PluginManager(
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
            #expect(requestCount(client) == 2)
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
        let (client, tempDir) = try makeEnvironment(serving: [(500, Data()), (500, Data())])

        let manager = PluginManager(
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
        let (client, tempDir) = try makeEnvironment(serving: [(200, fresh)])
        let manager = PluginManager(
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
        let (client, tempDir) = try makeEnvironment(serving: [(200, empty), (200, empty)])
        let manager = PluginManager(
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
