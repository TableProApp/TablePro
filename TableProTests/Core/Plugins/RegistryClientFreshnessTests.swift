//
//  RegistryClientFreshnessTests.swift
//  TableProTests
//

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
    private static let testTypeId = "TestFreshnessDB"

    private func manifestData(includingTestPlugin: Bool) -> Data {
        var plugins = ""
        if includingTestPlugin {
            plugins = """
            {
                "id": "com.test.freshness-driver",
                "name": "Freshness Test Driver",
                "version": "1.0.0",
                "summary": "test",
                "author": {"name": "Tester"},
                "category": "database-driver",
                "databaseTypeIds": ["\(Self.testTypeId)"],
                "minAppVersion": "999.0.0",
                "binaries": [
                    {"architecture": "arm64", "downloadURL": "https://x", "sha256": "deadbeef", "pluginKitVersion": 18},
                    {"architecture": "x86_64", "downloadURL": "https://x", "sha256": "deadbeef", "pluginKitVersion": 18}
                ]
            }
            """
        }
        return Data("{\"schemaVersion\": 2, \"plugins\": [\(plugins)]}".utf8)
    }

    private func makeEnvironment(
        cachedManifest: Data? = nil
    ) throws -> (client: RegistryClient, defaults: UserDefaults, tempDir: URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("registry-freshness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let cacheURL = tempDir.appendingPathComponent("registry-manifest.json")
        if let cachedManifest {
            try cachedManifest.write(to: cacheURL)
        }

        let suiteName = "registry-freshness-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockRegistryProtocol.self]
        let session = URLSession(configuration: config)

        let client = RegistryClient(
            userDefaults: defaults,
            session: session,
            manifestCacheURL: cacheURL
        )
        return (client, defaults, tempDir)
    }

    @Test("non-forced manifest request revalidates with the origin instead of trusting the local cache")
    func nonForcedRequestRevalidates() throws {
        let (client, _, _) = try makeEnvironment()
        let request = client.makeManifestRequest(forceRefresh: false)
        #expect(request.cachePolicy == .reloadRevalidatingCacheData)
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test("forced manifest request bypasses the local cache entirely")
    func forcedRequestIgnoresCache() throws {
        let (client, _, _) = try makeEnvironment()
        let request = client.makeManifestRequest(forceRefresh: true)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test("ifStale skips the network inside the freshness window")
    func ifStaleThrottlesInsideFreshnessWindow() async throws {
        MockRegistryProtocol.reset(responses: [
            (200, manifestData(includingTestPlugin: false)),
            (200, manifestData(includingTestPlugin: false))
        ])
        let (client, _, _) = try makeEnvironment()

        await client.ensureManifest(.ifStale)
        #expect(MockRegistryProtocol.requestCount == 1)
        #expect(client.fetchState == .loaded)

        await client.ensureManifest(.ifStale)
        #expect(MockRegistryProtocol.requestCount == 1)
    }

    @Test("mustBeCurrent revalidates even inside the freshness window")
    func mustBeCurrentAlwaysRevalidates() async throws {
        MockRegistryProtocol.reset(responses: [
            (200, manifestData(includingTestPlugin: false)),
            (200, manifestData(includingTestPlugin: true))
        ])
        let (client, _, _) = try makeEnvironment()

        await client.ensureManifest(.ifStale)
        #expect(MockRegistryProtocol.requestCount == 1)

        await client.ensureManifest(.mustBeCurrent)
        #expect(MockRegistryProtocol.requestCount == 2)
        #expect(client.manifest?.plugins.count == 1)
    }

    @Test("concurrent callers share one in-flight fetch")
    func concurrentCallersShareOneFetch() async throws {
        MockRegistryProtocol.reset(responses: [
            (200, manifestData(includingTestPlugin: false)),
            (200, manifestData(includingTestPlugin: false))
        ])
        let (client, _, _) = try makeEnvironment()

        async let first: Void = client.ensureManifest(.ifStale)
        async let second: Void = client.ensureManifest(.ifStale)
        _ = await (first, second)

        #expect(MockRegistryProtocol.requestCount == 1)
    }

    @Test("failed refresh keeps the cached manifest and reports it as cached")
    func failedRefreshKeepsCachedManifest() async throws {
        MockRegistryProtocol.reset(responses: [(500, Data())])
        let (client, _, _) = try makeEnvironment(cachedManifest: manifestData(includingTestPlugin: true))

        #expect(client.manifest != nil)
        await client.ensureManifest(.mustBeCurrent)

        #expect(client.manifest?.plugins.count == 1)
        guard case .loadedFromCache = client.fetchState else {
            Issue.record("Expected loadedFromCache, got \(client.fetchState)")
            return
        }
    }

    @Test("stale manifest miss triggers a fresh lookup before reporting not found")
    func staleManifestMissRevalidatesBeforeNotFound() async throws {
        let stale = manifestData(includingTestPlugin: false)
        let fresh = manifestData(includingTestPlugin: true)
        MockRegistryProtocol.reset(responses: [(200, stale), (200, fresh), (200, fresh)])
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
            if case .notFound = error {
                Issue.record("Lookup missed a plugin the forced revalidation should have found")
            }
            guard case .incompatibleWithCurrentApp = error else {
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

    @Test("registryPlugin resolves by database type id")
    func registryPluginLookup() throws {
        let manifest = try JSONDecoder().decode(RegistryManifest.self, from: manifestData(includingTestPlugin: true))
        #expect(PluginManager.registryPlugin(forTypeId: Self.testTypeId, in: manifest) != nil)
        #expect(PluginManager.registryPlugin(forTypeId: "SomethingElse", in: manifest) == nil)
        #expect(PluginManager.registryPlugin(forTypeId: Self.testTypeId, in: nil) == nil)
    }
}
