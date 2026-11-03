import CryptoKit
import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

private final class ManifestStubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bodies: [URL: Data] = [:]
    nonisolated(unsafe) private static var requests: [URL: Int] = [:]
    nonisolated(unsafe) private static var unansweredRequests: [URL: Int] = [:]

    static func serve(_ body: Data, at url: URL) {
        lock.withLock { bodies[url] = body }
    }

    // An unanswered request stays open until its task is cancelled, like one waiting for the network.
    static func leaveUnanswered(next count: Int, at url: URL) {
        lock.withLock { unansweredRequests[url] = count }
    }

    static func requestCount(for url: URL) -> Int {
        lock.withLock { requests[url, default: 0] }
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
        let body: Data? = Self.lock.withLock {
            Self.requests[url, default: 0] += 1
            guard Self.unansweredRequests[url, default: 0] == 0 else {
                Self.unansweredRequests[url, default: 0] -= 1
                return nil
            }
            return Self.bodies[url] ?? Data()
        }
        guard let body else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@discardableResult
private func writeBundle(
    at url: URL,
    bundleId: String,
    build: Int,
    kit: Int = PluginManager.currentPluginKitVersion,
    extraInfo: [String: Any] = [:]
) throws -> URL {
    let contents = url.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    var info: [String: Any] = [
        "CFBundleIdentifier": bundleId,
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": String(build),
        "TableProPluginKitVersion": kit
    ]
    info.merge(extraInfo) { _, new in new }
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
    return url
}

// Writes an unsigned bundle where the signed download would land, then places it with the installer's helpers.
private actor FixtureRegistryInstaller: RegistryPluginInstalling {
    private(set) var installedIds: [String] = []
    private(set) var stagedIds: [String] = []
    private let installGate: AsyncGate?
    private let stageGate: AsyncGate?
    private let archiveBuild: Int?

    // archiveBuild is what the downloaded bundle's Info.plist says when it is not the manifest's build.
    init(installGate: AsyncGate? = nil, stageGate: AsyncGate? = nil, archiveBuild: Int? = nil) {
        self.installGate = installGate
        self.stageGate = stageGate
        self.archiveBuild = archiveBuild
    }

    func install(
        _ registryPlugin: RegistryPlugin,
        release: RegistryRelease,
        into userPluginsDir: URL,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> URL {
        installedIds.append(registryPlugin.id)
        await installGate?.wait()
        let download = try downloadedBundle(registryPlugin, release: release, beside: userPluginsDir, named: "Driver.tableplugin")
        let destURL = userPluginsDir.appendingPathComponent("Driver.tableplugin", isDirectory: true)
        return try PluginInstaller.atomicReplace(stagedBundleURL: download, destURL: destURL)
    }

    func stage(
        _ registryPlugin: RegistryPlugin,
        release: RegistryRelease,
        pluginId: String,
        bundleName: String,
        into userPluginsDir: URL,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> URL {
        stagedIds.append(registryPlugin.id)
        await stageGate?.wait()
        let download = try downloadedBundle(registryPlugin, release: release, beside: userPluginsDir, named: bundleName)
        return try PluginInstaller.stage(
            bundleAt: download,
            pluginId: pluginId,
            bundleName: bundleName,
            userPluginsDir: userPluginsDir
        )
    }

    private func downloadedBundle(
        _ registryPlugin: RegistryPlugin,
        release: RegistryRelease,
        beside userPluginsDir: URL,
        named bundleName: String
    ) throws -> URL {
        let url = userPluginsDir.deletingLastPathComponent()
            .appendingPathComponent("Download-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(bundleName, isDirectory: true)
        return try writeBundle(at: url, bundleId: registryPlugin.id, build: archiveBuild ?? release.build)
    }
}

@Suite("Plugin registry update pass", .serialized)
@MainActor
struct PluginRegistryUpdatePassTests {
    private let registryDefaults: EphemeralDefaults

    init() throws {
        registryDefaults = try EphemeralDefaults()
    }

    private struct Fixture {
        let manager: PluginManager
        let pluginsDir: URL
        let root: URL
    }

    private func makeFixture(
        installer: any RegistryPluginInstalling = PluginInstaller.shared,
        isUpdatingEnabled: Bool = false
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginRegistryUpdatePassTests-\(UUID().uuidString)", isDirectory: true)
        let pluginsDir = root.appendingPathComponent("Plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        let manager = PluginManager(
            builtInPluginsURL: nil,
            userPluginsDir: pluginsDir,
            registryInstaller: installer,
            isUpdatingEnabled: isUpdatingEnabled
        )
        return Fixture(manager: manager, pluginsDir: pluginsDir, root: root)
    }

    private func stageUpdate(
        of bundleId: String,
        stagedAs pluginId: String? = nil,
        build: Int,
        kit: Int = PluginManager.currentPluginKitVersion,
        extraInfo: [String: Any] = [:],
        in fixture: Fixture
    ) throws {
        let downloaded = try writeBundle(
            at: fixture.root.appendingPathComponent("Download-\(UUID().uuidString)/Driver.tableplugin", isDirectory: true),
            bundleId: bundleId,
            build: build,
            kit: kit,
            extraInfo: extraInfo
        )
        try PluginInstaller.stage(
            bundleAt: downloaded,
            pluginId: pluginId ?? bundleId,
            bundleName: "Driver.tableplugin",
            userPluginsDir: fixture.pluginsDir
        )
    }

    private func makeEntry(
        id: String,
        in pluginsDir: URL,
        build: Int,
        source: PluginSource = .userInstalled
    ) -> PluginEntry {
        PluginEntry(
            id: id,
            bundle: Bundle.main,
            url: pluginsDir.appendingPathComponent("\(id).tableplugin", isDirectory: true),
            source: source,
            name: id,
            version: "1.0",
            build: build,
            pluginDescription: "",
            capabilities: [.databaseDriver],
            databaseTypeId: nil,
            additionalTypeIds: [],
            pluginIconName: "puzzlepiece",
            defaultPort: nil,
            exportFormatId: nil,
            importFormatId: nil
        )
    }

    private func makeRelease(build: Int, kit: Int = PluginManager.currentPluginKitVersion) -> RegistryRelease {
        RegistryRelease(
            version: "0.82.0",
            build: build,
            channel: "stable",
            pluginKit: kit,
            minimumSystemVersion: "13.0",
            url: "https://x",
            sha256: "deadbeef"
        )
    }

    private func makeRegistryPlugin(id: String = "com.example.driver", releases: [RegistryRelease]) -> RegistryPlugin {
        RegistryPlugin(
            id: id,
            name: "Test Plugin",
            databaseTypeIds: [],
            exportFormatIds: [],
            releases: releases
        )
    }

    private func makeManifest(_ plugins: [RegistryPlugin]) -> RegistryManifest {
        RegistryManifest(schemaVersion: RegistryManifest.supportedSchemaVersion, plugins: plugins)
    }

    private func makeRejected(
        bundleId: String? = nil,
        registryId: String? = nil,
        isOutdated: Bool = true,
        providedDatabaseTypeIds: [String] = []
    ) -> RejectedPlugin {
        RejectedPlugin(
            url: URL(fileURLWithPath: "/tmp/test-\(UUID().uuidString).tableplugin"),
            bundleId: bundleId,
            registryId: registryId,
            name: "Test",
            reason: "Built for an older PluginKit",
            isOutdated: isOutdated,
            providedDatabaseTypeIds: providedDatabaseTypeIds
        )
    }

    private func pending(
        _ targets: [RegistryUpdateTarget],
        in manifest: RegistryManifest
    ) -> [PendingRegistryUpdate] {
        PluginManager.pendingRegistryUpdates(
            installed: targets,
            manifest: manifest,
            channel: .stable,
            kits: PluginManager.compatibleKits,
            systemVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        )
    }

    // signedBy nil serves the manifest with no signature beside it.
    private func makeRegistryClient(
        servingBuild build: Int,
        pluginIds: [String] = ["com.example.driver"],
        signedBy key: Curve25519.Signing.PrivateKey? = SignedRegistryManifest.key
    ) throws -> (client: RegistryClient, manifestURL: URL) {
        let manifestURL = try #require(URL(string: "https://registry.invalid/\(UUID().uuidString)/plugins/v3.json"))
        let plugins = pluginIds.map { id in
            """
            {"id": "\(id)", "name": "Driver", "databaseTypeIds": [], "exportFormatIds": [], "releases": [{
                "version": "1.0", "build": \(build), "channel": "stable",
                "pluginKit": \(PluginManager.currentPluginKitVersion),
                "minimumSystemVersion": "13.0", "url": "https://x", "sha256": "deadbeef"
            }]}
            """
        }
        let body = Data("""
        {"schemaVersion": 3, "serial": 1, "retainFromPluginKit": 39, "plugins": [\(plugins.joined(separator: ","))]}
        """.utf8)
        ManifestStubProtocol.serve(body, at: manifestURL)
        if let key {
            ManifestStubProtocol.serve(
                try SignedRegistryManifest.signature(of: body, by: key),
                at: SignedRegistryManifest.signatureURL(for: manifestURL)
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ManifestStubProtocol.self]
        let client = SignedRegistryManifest.client(
            manifestURL: manifestURL,
            session: URLSession(configuration: configuration),
            defaults: registryDefaults.defaults
        )
        return (client, manifestURL)
    }

    // MARK: - Pending updates

    @Test("A lower installed build updates; an equal build does not")
    func lowerBuildUpdatesEqualBuildDoesNot() {
        let manifest = makeManifest([
            makeRegistryPlugin(id: "com.example.lower", releases: [makeRelease(build: 820_100)]),
            makeRegistryPlugin(id: "com.example.equal", releases: [makeRelease(build: 820_100)])
        ])
        let targets = [
            RegistryUpdateTarget(pluginId: "com.example.lower", build: 820_000, rejectedURL: nil),
            RegistryUpdateTarget(pluginId: "com.example.equal", build: 820_100, rejectedURL: nil)
        ]

        let updates = pending(targets, in: manifest)
        let updatedIds = updates.map { $0.target.pluginId }

        #expect(updatedIds == ["com.example.lower"])
        #expect(updates.first?.release.build == 820_100)
    }

    @Test("A rejected plugin counts as build 0, so any selectable release repairs it")
    func rejectedPluginTakesAnySelectableRelease() {
        let manifest = makeManifest([makeRegistryPlugin(releases: [makeRelease(build: 1)])])
        let target = RegistryUpdateTarget(
            pluginId: "com.example.driver",
            build: 0,
            rejectedURL: URL(fileURLWithPath: "/tmp/Driver.tableplugin")
        )

        let builds = pending([target], in: manifest).map { $0.release.build }

        #expect(builds == [1])
    }

    @Test("A release outside the PluginKit range is never an update")
    func releaseOutsideKitRangeSkipped() {
        let manifest = makeManifest([
            makeRegistryPlugin(releases: [makeRelease(build: 900_000, kit: PluginManager.currentPluginKitVersion + 1)])
        ])
        let target = RegistryUpdateTarget(pluginId: "com.example.driver", build: 1, rejectedURL: nil)

        #expect(pending([target], in: manifest).isEmpty)
    }

    // MARK: - Targets

    @Test("A user plugin below the app build with a registry sidecar is a target; without a sidecar it never is")
    func sidecarDecidesTarget() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = fixture.manager
        let withSidecar = makeEntry(id: "com.example.registry", in: fixture.pluginsDir, build: 10)
        let withoutSidecar = makeEntry(id: "com.example.local", in: fixture.pluginsDir, build: 10)
        manager.saveRegistryMetadata(pluginId: withSidecar.id, pluginURL: withSidecar.url)
        manager.plugins = [withSidecar, withoutSidecar]

        let targets = manager.registryUpdateTargets(appBuild: 20)

        #expect(targets == [RegistryUpdateTarget(pluginId: "com.example.registry", build: 10, rejectedURL: nil)])
    }

    @Test("A plugin at the app build, a built-in plugin and a staged plugin are not targets")
    func currentBuiltInAndStagedAreNotTargets() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = fixture.manager
        let current = makeEntry(id: "com.example.current", in: fixture.pluginsDir, build: 20)
        let builtIn = makeEntry(id: "com.example.builtin", in: fixture.pluginsDir, build: 10, source: .builtIn)
        let staged = makeEntry(id: "com.example.staged", in: fixture.pluginsDir, build: 10)
        for entry in [current, builtIn, staged] {
            manager.saveRegistryMetadata(pluginId: entry.id, pluginURL: entry.url)
        }
        manager.plugins = [current, builtIn, staged]
        manager.stagedPluginIds = [staged.id]

        #expect(manager.registryUpdateTargets(appBuild: 20).isEmpty)
    }

    @Test("Rejected plugins are updated before loaded ones")
    func rejectedTargetsComeFirst() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = fixture.manager
        let loaded = makeEntry(id: "com.example.loaded", in: fixture.pluginsDir, build: 10)
        manager.saveRegistryMetadata(pluginId: loaded.id, pluginURL: loaded.url)
        manager.plugins = [loaded]
        manager.rejectedPlugins = [makeRejected(bundleId: "com.example.rejected")]

        let order = manager.registryUpdateTargets(appBuild: 20).map { $0.pluginId }

        #expect(order == ["com.example.rejected", "com.example.loaded"])
    }

    @Test("A plugin rejected as outdated is a target at build 0; one rejected for another reason is not")
    func outdatedRejectionsAreTargets() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = fixture.manager
        let outdated = makeRejected(bundleId: "com.example.outdated")
        let broken = makeRejected(bundleId: "com.example.broken", isOutdated: false)
        manager.rejectedPlugins = [outdated, broken]

        let targets = manager.registryUpdateTargets(appBuild: 20)

        #expect(targets == [RegistryUpdateTarget(pluginId: "com.example.outdated", build: 0, rejectedURL: outdated.url)])
    }

    @Test("A target uninstalled, removed, staged or replaced by a file while the pass waits is skipped")
    func targetsAreRevalidatedBeforeApplying() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = fixture.manager
        let entry = makeEntry(id: "com.example.driver", in: fixture.pluginsDir, build: 10)
        manager.saveRegistryMetadata(pluginId: entry.id, pluginURL: entry.url)
        let rejected = makeRejected(bundleId: "com.example.outdated")
        manager.plugins = [entry]
        manager.rejectedPlugins = [rejected]
        let loadedTarget = RegistryUpdateTarget(pluginId: entry.id, build: 10, rejectedURL: nil)
        let rejectedTarget = RegistryUpdateTarget(pluginId: "com.example.outdated", build: 0, rejectedURL: rejected.url)
        #expect(manager.isRegistryUpdateTarget(loadedTarget))
        #expect(manager.isRegistryUpdateTarget(rejectedTarget))

        manager.stagedPluginIds = [entry.id]
        #expect(!manager.isRegistryUpdateTarget(loadedTarget))
        manager.stagedPluginIds = []

        manager.plugins = [makeEntry(id: entry.id, in: fixture.pluginsDir, build: 30)]
        #expect(!manager.isRegistryUpdateTarget(loadedTarget))

        manager.plugins = [entry]
        manager.removeRegistryMetadata(for: entry.url)
        #expect(!manager.isRegistryUpdateTarget(loadedTarget))

        manager.plugins = []
        manager.removeFromRejected(url: rejected.url)
        #expect(!manager.isRegistryUpdateTarget(loadedTarget))
        #expect(!manager.isRegistryUpdateTarget(rejectedTarget))
    }

    // MARK: - The pass

    @Test("No targets means no manifest fetch")
    func noTargetsNoFetch() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let registry = try OfflineRegistry()

        let result = await fixture.manager.runRegistryUpdatePass(registryClient: registry.client, appBuild: 20)

        #expect(result == .finished)
        #expect(registry.requestCount == 0)
    }

    @Test("Try Again repairs a rejected plugin as soon as the registry answers")
    func tryAgainRepairsARejectedPlugin() async throws {
        let installer = FixtureRegistryInstaller()
        let fixture = try makeFixture(installer: installer, isUpdatingEnabled: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.manager.rejectedPlugins = [makeRejected(bundleId: "com.example.driver")]
        let (client, manifestURL) = try makeRegistryClient(servingBuild: 20)

        let reached = await fixture.manager.retryRejectedPluginRepairs(registryClient: client)

        #expect(reached)
        #expect(ManifestStubProtocol.requestCount(for: manifestURL) == 1)
        let installedIds = await installer.installedIds
        #expect(installedIds == ["com.example.driver"])
    }

    @Test("Try Again with the registry still refused reports it and installs nothing")
    func tryAgainReportsAnUnreachableRegistry() async throws {
        let installer = FixtureRegistryInstaller()
        let fixture = try makeFixture(installer: installer, isUpdatingEnabled: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.manager.rejectedPlugins = [makeRejected(bundleId: "com.example.driver")]
        let (client, _) = try makeRegistryClient(servingBuild: 20, signedBy: nil)

        let reached = await fixture.manager.retryRejectedPluginRepairs(registryClient: client)

        #expect(!reached)
        let installedIds = await installer.installedIds
        #expect(installedIds.isEmpty)
        #expect(fixture.manager.rejectedPlugins.count == 1)
    }

    @Test("Try Again does nothing where updating is off")
    func tryAgainNeedsUpdating() async throws {
        let fixture = try makeFixture(isUpdatingEnabled: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.manager.rejectedPlugins = [makeRejected(bundleId: "com.example.driver")]
        let registry = try OfflineRegistry()

        let reached = await fixture.manager.retryRejectedPluginRepairs(registryClient: registry.client)

        #expect(!reached)
        #expect(registry.requestCount == 0)
    }

    @Test("A manifest without a newer build yet keeps the pass retrying")
    func staleManifestRetries() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = fixture.manager
        let entry = makeEntry(id: "com.example.driver", in: fixture.pluginsDir, build: 10)
        manager.saveRegistryMetadata(pluginId: entry.id, pluginURL: entry.url)
        manager.plugins = [entry]
        let (client, manifestURL) = try makeRegistryClient(servingBuild: 10)

        let result = await manager.runRegistryUpdatePass(registryClient: client, appBuild: 20)

        #expect(result == .retry)
        #expect(ManifestStubProtocol.requestCount(for: manifestURL) == 1)
        #expect(manager.stagedPluginIds.isEmpty)
    }

    @Test("The pass fetches on a session that waits for the network; interactive fetches keep the 30 s one")
    func passSessionWaitsForConnectivity() throws {
        let manifestURL = try #require(URL(string: "https://registry.invalid/\(UUID().uuidString)/plugins/v3.json"))
        let client = RegistryClient(manifestURL: manifestURL, session: RegistryClient.makeDefaultSession())
        let interactive = client.session.configuration
        let pass = client.updatePassSession.configuration

        #expect(pass.waitsForConnectivity)
        #expect(pass.timeoutIntervalForResource == 7 * 24 * 60 * 60)
        #expect(interactive.timeoutIntervalForResource == 30)
        #expect(pass.urlCache === interactive.urlCache)
    }

    @Test("While the pass waits for the manifest, connecting repairs the plugin with a manifest request of its own")
    func connectionRepairsWhileThePassWaitsForTheNetwork() async throws {
        let installer = FixtureRegistryInstaller()
        let fixture = try makeFixture(installer: installer, isUpdatingEnabled: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = fixture.manager
        manager.rejectedPlugins = [
            makeRejected(bundleId: "com.example.driver", providedDatabaseTypeIds: [DatabaseType.mssql.pluginTypeId])
        ]
        let (client, manifestURL) = try makeRegistryClient(servingBuild: 20)
        ManifestStubProtocol.leaveUnanswered(next: 1, at: manifestURL)

        let pass = Task { await manager.runRegistryUpdatePass(registryClient: client, appBuild: 20) }
        try await waitUntil { ManifestStubProtocol.requestCount(for: manifestURL) == 1 }

        try await manager.prepareForConnecting(to: .mssql, registryClient: client)

        #expect(ManifestStubProtocol.requestCount(for: manifestURL) == 2)
        let installedIds = await installer.installedIds
        #expect(installedIds == ["com.example.driver"])
        pass.cancel()
        let result = await pass.value
        #expect(result == .retry)
    }

    @Test("A pass whose manifest arrives during a connection's repair waits for it, then skips the plugin it repaired")
    func passWaitsForAConnectionsRepair() async throws {
        let installGate = AsyncGate()
        let installer = FixtureRegistryInstaller(installGate: installGate)
        let fixture = try makeFixture(installer: installer, isUpdatingEnabled: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = fixture.manager
        let typeId = DatabaseType.mssql.pluginTypeId
        let rejected = makeRejected(bundleId: "com.example.driver", providedDatabaseTypeIds: [typeId])
        manager.rejectedPlugins = [rejected]
        let (client, _) = try makeRegistryClient(servingBuild: 20)

        let connection = Task { await manager.ensurePluginReady(forTypeId: typeId, registryClient: client) }
        await installGate.arrived(1)
        let pass = Task { await manager.runRegistryUpdatePass(registryClient: client, appBuild: 20) }
        try await waitUntil { manager.rejectedRepairWaiters.count == 1 }
        // Stands in for the load, which the unsigned fixture cannot pass.
        manager.removeFromRejected(url: rejected.url)
        await installGate.open()
        await connection.value

        let result = await pass.value
        #expect(result == .finished)
        let installedIds = await installer.installedIds
        #expect(installedIds == ["com.example.driver"])
    }

    @Test("A connection that arrives during the pass's repair waits for it, then skips the plugin it repaired")
    func connectionWaitsForThePassRepair() async throws {
        let installGate = AsyncGate()
        let installer = FixtureRegistryInstaller(installGate: installGate)
        let fixture = try makeFixture(installer: installer, isUpdatingEnabled: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = fixture.manager
        let typeId = DatabaseType.mssql.pluginTypeId
        let rejected = makeRejected(bundleId: "com.example.driver", providedDatabaseTypeIds: [typeId])
        manager.rejectedPlugins = [rejected]
        let (client, manifestURL) = try makeRegistryClient(servingBuild: 20)

        let pass = Task { await manager.runRegistryUpdatePass(registryClient: client, appBuild: 20) }
        await installGate.arrived(1)
        let connection = Task { await manager.ensurePluginReady(forTypeId: typeId, registryClient: client) }
        try await waitUntil { manager.rejectedRepairWaiters.count == 1 }
        // Stands in for the load, which the unsigned fixture cannot pass.
        manager.removeFromRejected(url: rejected.url)
        await installGate.open()
        await connection.value

        #expect(ManifestStubProtocol.requestCount(for: manifestURL) == 1)
        let installedIds = await installer.installedIds
        #expect(installedIds == ["com.example.driver"])
        _ = await pass.value
    }

    @Test("Retries wait 30 s, 300 s, then 600 s, and stop after the fifth attempt")
    func retryBackoff() {
        let delays = (1...5).map { PluginManager.registryUpdateRetryDelay(afterAttempt: $0) }

        #expect(delays == [.seconds(30), .seconds(300), .seconds(600), .seconds(600), nil])
    }

    @Test("registryUpdateMode installs a plugin that is not loaded and stages a loaded one")
    func updateModeRouting() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = fixture.manager
        manager.plugins = [makeEntry(id: "com.example.loaded", in: fixture.pluginsDir, build: 10)]
        manager.rejectedPlugins = [makeRejected(bundleId: "com.example.rejected")]

        #expect(manager.registryUpdateMode(forPluginId: "com.example.loaded") == .stageForNextLaunch)
        #expect(manager.registryUpdateMode(forPluginId: "com.example.rejected") == .installNow)
        #expect(manager.registryUpdateMode(forPluginId: "com.example.absent") == .installNow)
    }

    @Test("The pass stages a loaded plugin's newer build for the next launch and keeps its sidecar")
    func passStagesLoadedPlugin() async throws {
        let installer = FixtureRegistryInstaller()
        let fixture = try makeFixture(installer: installer)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = fixture.manager
        let entry = makeEntry(id: "com.example.driver", in: fixture.pluginsDir, build: 10)
        manager.saveRegistryMetadata(pluginId: entry.id, pluginURL: entry.url)
        manager.plugins = [entry]
        let (client, _) = try makeRegistryClient(servingBuild: 20)

        let result = await manager.runRegistryUpdatePass(registryClient: client, appBuild: 20)

        #expect(result == .finished)
        #expect(manager.stagedPluginIds == [entry.id])
        let stagedBundle = PluginInstaller.stagedUpdateDirectory(for: entry.id, in: fixture.pluginsDir)
            .appendingPathComponent(entry.url.lastPathComponent, isDirectory: true)
        #expect(PluginManager.bundleBuild(at: stagedBundle) == 20)
        #expect(PluginManager.readRegistryMetadata(for: entry.url)?.pluginId == entry.id)
        let installedIds = await installer.installedIds
        #expect(installedIds.isEmpty)
    }

    @Test("The pass keeps the installed Oracle driver when the manifest claims a newer build than the archive holds")
    func passKeepsInstalledPluginWhenTheArchiveIsOlder() async throws {
        let installer = FixtureRegistryInstaller(archiveBuild: 820_099)
        let fixture = try makeFixture(installer: installer)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = fixture.manager
        let entry = makeEntry(id: "com.TablePro.OracleDriver", in: fixture.pluginsDir, build: 840_099)
        try writeBundle(at: entry.url, bundleId: entry.id, build: 840_099)
        manager.saveRegistryMetadata(pluginId: entry.id, pluginURL: entry.url)
        manager.plugins = [entry]
        let (client, _) = try makeRegistryClient(servingBuild: 99_999_999, pluginIds: [entry.id])

        let result = await manager.runRegistryUpdatePass(registryClient: client, appBuild: 840_199)
        PluginManager.applyStagedUpdates(in: fixture.pluginsDir)

        #expect(result == .retry)
        #expect(manager.stagedPluginIds.isEmpty)
        let stagedDir = PluginInstaller.stagedUpdateDirectory(for: entry.id, in: fixture.pluginsDir)
        #expect(!FileManager.default.fileExists(atPath: stagedDir.path))
        #expect(PluginManager.bundleBuild(at: entry.url) == 840_099)
        #expect(PluginManager.readRegistryMetadata(for: entry.url)?.pluginId == entry.id)
    }

    @Test("A manifest with no signature, or one signed by another key, never reaches the installer", arguments: [
        nil, Curve25519.Signing.PrivateKey()
    ])
    func unsignedManifestNeverInstalls(signedBy key: Curve25519.Signing.PrivateKey?) async throws {
        let installer = FixtureRegistryInstaller(archiveBuild: 820_099)
        let fixture = try makeFixture(installer: installer)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = fixture.manager
        let entry = makeEntry(id: "com.TablePro.OracleDriver", in: fixture.pluginsDir, build: 840_099)
        try writeBundle(at: entry.url, bundleId: entry.id, build: 840_099)
        manager.saveRegistryMetadata(pluginId: entry.id, pluginURL: entry.url)
        manager.plugins = [entry]
        manager.rejectedPlugins = [makeRejected(bundleId: "com.example.driver")]
        let (client, _) = try makeRegistryClient(
            servingBuild: 99_999_999, pluginIds: [entry.id, "com.example.driver"], signedBy: key
        )

        let result = await manager.runRegistryUpdatePass(registryClient: client, appBuild: 840_199)

        #expect(result == .retry)
        #expect(client.manifest == nil)
        let stagedIds = await installer.stagedIds
        let installedIds = await installer.installedIds
        #expect(stagedIds.isEmpty)
        #expect(installedIds.isEmpty)
    }

    @Test("The pass installs a rejected plugin at once, and a build that fails to load keeps it rejected")
    func passInstallsRejectedPluginNow() async throws {
        let installer = FixtureRegistryInstaller()
        let fixture = try makeFixture(installer: installer)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = fixture.manager
        let rejectedURL = fixture.pluginsDir.appendingPathComponent("Driver.tableplugin", isDirectory: true)
        manager.rejectedPlugins = [RejectedPlugin(
            url: rejectedURL,
            bundleId: "com.example.driver",
            registryId: nil,
            name: "Driver",
            reason: "Built for an older PluginKit",
            isOutdated: true,
            providedDatabaseTypeIds: []
        )]
        let (client, _) = try makeRegistryClient(servingBuild: 20)

        let result = await manager.runRegistryUpdatePass(registryClient: client, appBuild: 20)

        let installedIds = await installer.installedIds
        let stagedIds = await installer.stagedIds
        #expect(installedIds == ["com.example.driver"])
        #expect(stagedIds.isEmpty)
        #expect(manager.stagedPluginIds.isEmpty)
        #expect(PluginManager.bundleBuild(at: rejectedURL) == 20)
        // The fixture is unsigned, so the load fails and the entry stays.
        #expect(result == .retry)
        #expect(manager.rejectedPlugins.map { $0.url } == [rejectedURL])
    }

    @Test("A connection waits for the pass's rejected repairs, not for its staging downloads")
    func repairPhaseEndsBeforeStaging() async throws {
        let installGate = AsyncGate()
        let stageGate = AsyncGate()
        let installer = FixtureRegistryInstaller(installGate: installGate, stageGate: stageGate)
        let fixture = try makeFixture(installer: installer)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = fixture.manager
        let loaded = makeEntry(id: "com.example.loaded", in: fixture.pluginsDir, build: 10)
        manager.saveRegistryMetadata(pluginId: loaded.id, pluginURL: loaded.url)
        manager.plugins = [loaded]
        manager.rejectedPlugins = [makeRejected(bundleId: "com.example.driver")]
        let (client, _) = try makeRegistryClient(servingBuild: 20, pluginIds: ["com.example.driver", loaded.id])

        let pass = Task { await manager.runRegistryUpdatePass(registryClient: client, appBuild: 20) }
        await installGate.arrived(1)
        #expect(manager.isRepairingRejectedPlugins)
        await installGate.open()
        await stageGate.arrived(1)
        #expect(!manager.isRepairingRejectedPlugins)
        await stageGate.open()
        _ = await pass.value

        #expect(manager.stagedPluginIds == [loaded.id])
    }

    @Test("A file at or above the app's build staged over a loaded registry plugin drops its sidecar")
    func fileStagedOverRegistryPluginDropsSidecar() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = fixture.manager
        let entry = makeEntry(id: "com.example.driver", in: fixture.pluginsDir, build: 10)
        manager.saveRegistryMetadata(pluginId: entry.id, pluginURL: entry.url)
        manager.plugins = [entry]
        let file = try writeBundle(
            at: fixture.root.appendingPathComponent("Downloads/Driver.tableplugin", isDirectory: true),
            bundleId: entry.id,
            build: 11
        )

        _ = try manager.stageForNextLaunch(bundleAt: file, replacing: entry, appBuild: 11)

        #expect(manager.stagedPluginIds == [entry.id])
        #expect(PluginManager.readRegistryMetadata(for: entry.url) == nil)
        manager.stagedPluginIds = []
        #expect(manager.registryUpdateTargets(appBuild: 11).isEmpty)
    }

    @Test("A newer file below the app's build is staged and stays under the update pass")
    func newerFileBelowAppBuildKeepsSidecar() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = fixture.manager
        let entry = makeEntry(id: "com.example.driver", in: fixture.pluginsDir, build: 10)
        manager.saveRegistryMetadata(pluginId: entry.id, pluginURL: entry.url)
        manager.plugins = [entry]
        let file = try writeBundle(
            at: fixture.root.appendingPathComponent("Downloads/Driver.tableplugin", isDirectory: true),
            bundleId: entry.id,
            build: 11
        )

        _ = try manager.stageForNextLaunch(bundleAt: file, replacing: entry, appBuild: 20)

        #expect(manager.stagedPluginIds == [entry.id])
        #expect(PluginManager.readRegistryMetadata(for: entry.url)?.pluginId == entry.id)
    }

    @Test("A file between the loaded build and the staged update is refused, and the staged update stays")
    func fileBelowTheStagedUpdateIsRefused() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = fixture.manager
        let entry = makeEntry(id: "com.TablePro.SnowflakeDriver", in: fixture.pluginsDir, build: 840_099)
        manager.saveRegistryMetadata(pluginId: entry.id, pluginURL: entry.url)
        manager.plugins = [entry]
        let update = try writeBundle(
            at: fixture.root.appendingPathComponent("Download-\(UUID().uuidString)/Driver.tableplugin", isDirectory: true),
            bundleId: entry.id,
            build: 860_099
        )
        let stagedURL = try PluginInstaller.stage(
            bundleAt: update,
            pluginId: entry.id,
            bundleName: entry.url.lastPathComponent,
            userPluginsDir: fixture.pluginsDir
        )
        manager.stagedPluginIds = [entry.id]
        let file = try writeBundle(
            at: fixture.root.appendingPathComponent("Downloads/Driver.tableplugin", isDirectory: true),
            bundleId: entry.id,
            build: 850_001
        )

        #expect(throws: PluginError.self) {
            _ = try manager.stageForNextLaunch(bundleAt: file, replacing: entry, appBuild: 860_099)
        }

        #expect(PluginManager.bundleBuild(at: stagedURL) == 860_099)
        #expect(manager.stagedPluginIds == [entry.id])
        #expect(PluginManager.readRegistryMetadata(for: entry.url)?.pluginId == entry.id)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("A file holding an older build than the loaded plugin is refused, and nothing is staged")
    func olderFileOverLoadedPluginIsRefused() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = fixture.manager
        let entry = makeEntry(id: "com.TablePro.SnowflakeDriver", in: fixture.pluginsDir, build: 850_099)
        manager.saveRegistryMetadata(pluginId: entry.id, pluginURL: entry.url)
        manager.plugins = [entry]
        let file = try writeBundle(
            at: fixture.root.appendingPathComponent("Downloads/Driver.tableplugin", isDirectory: true),
            bundleId: entry.id,
            build: 840_099
        )

        let error = #expect(throws: PluginError.self) {
            _ = try manager.stageForNextLaunch(bundleAt: file, replacing: entry)
        }

        guard case .installFailed(let reason) = error else {
            Issue.record("Expected installFailed, got \(String(describing: error))")
            return
        }
        #expect(reason.contains("840099") && reason.contains("850099"))
        #expect(manager.stagedPluginIds.isEmpty)
        let stagedDir = PluginInstaller.stagedUpdateDirectory(for: entry.id, in: fixture.pluginsDir)
        #expect(!FileManager.default.fileExists(atPath: stagedDir.path))
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(PluginManager.readRegistryMetadata(for: entry.url)?.pluginId == entry.id)
    }

    @Test("A file holding the loaded plugin's own build is staged and keeps it under the update pass")
    func sameBuildFileKeepsSidecar() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = fixture.manager
        let entry = makeEntry(id: "com.example.driver", in: fixture.pluginsDir, build: 10)
        manager.saveRegistryMetadata(pluginId: entry.id, pluginURL: entry.url)
        manager.plugins = [entry]
        let file = try writeBundle(
            at: fixture.root.appendingPathComponent("Downloads/Driver.tableplugin", isDirectory: true),
            bundleId: entry.id,
            build: 10
        )

        _ = try manager.stageForNextLaunch(bundleAt: file, replacing: entry, appBuild: 11)

        #expect(manager.stagedPluginIds == [entry.id])
        #expect(PluginManager.readRegistryMetadata(for: entry.url)?.pluginId == entry.id)
    }

    @Test("A file is refused only when its build is below the installed one", arguments: [
        (9, 10, true), (10, 10, false), (11, 10, false), (1, nil, false)
    ])
    func olderFileRule(fileBuild: Int, installedBuild: Int?, refused: Bool) {
        let threw = (try? PluginManager.refuseOlderFile(build: fileBuild, installedBuild: installedBuild)) == nil
        #expect(threw == refused)
    }

    @Test("A rejected plugin's installed build is read from its bundle, by bundle id or registry id")
    func rejectedBuildIsReadFromTheBundle() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = fixture.manager
        let url = fixture.pluginsDir.appendingPathComponent("Driver.tableplugin", isDirectory: true)
        let outdatedKit = PluginManager.minimumCompatiblePluginKitVersion - 1
        try writeBundle(at: url, bundleId: "com.example.driver", build: 30, kit: outdatedKit)
        manager.rejectedPlugins = [RejectedPlugin(
            url: url,
            bundleId: "com.example.driver",
            registryId: "com.example.registry-driver",
            name: "Driver",
            reason: "Built for an older PluginKit",
            isOutdated: true,
            providedDatabaseTypeIds: []
        )]

        #expect(manager.rejectedBuild(of: "com.example.driver") == 30)
        #expect(manager.rejectedBuild(of: "com.example.registry-driver") == 30)
        #expect(manager.rejectedBuild(of: "com.example.other") == nil)
    }

    @Test("Connecting repairs only the outdated plugins that provide its database type")
    func connectTargetsOnlyThatType() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = fixture.manager
        let loaded = makeEntry(id: "com.example.loaded", in: fixture.pluginsDir, build: 10)
        manager.saveRegistryMetadata(pluginId: loaded.id, pluginURL: loaded.url)
        manager.plugins = [loaded]
        let wanted = makeRejected(bundleId: "com.example.wanted", providedDatabaseTypeIds: ["WantedDB"])
        let other = makeRejected(bundleId: "com.example.other", providedDatabaseTypeIds: ["OtherDB"])
        manager.rejectedPlugins = [wanted, other]

        let targets = manager.registryUpdateTargets(forTypeId: "WantedDB", appBuild: 20)

        #expect(targets == [RegistryUpdateTarget(pluginId: "com.example.wanted", build: 0, rejectedURL: wanted.url)])
    }

    @Test("A rejected plugin replaced in place passes the kit check at once")
    func inPlaceRepairPassesKitCheck() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let url = fixture.pluginsDir.appendingPathComponent("Driver.tableplugin", isDirectory: true)
        let outdatedKit = PluginManager.minimumCompatiblePluginKitVersion - 1
        try writeBundle(at: url, bundleId: "com.example.driver", build: 1, kit: outdatedKit)
        let cached = try #require(Bundle(url: url))
        #expect(throws: PluginError.self) { try PluginManager.validateBundleVersions(cached) }

        try writeBundle(at: url, bundleId: "com.example.driver", build: 2)

        #expect(cached.infoDictionary?["TableProPluginKitVersion"] as? Int == outdatedKit)
        try PluginManager.validateBundleVersions(try #require(Bundle(url: url)))
    }

    // MARK: - Launch swap

    @Test("Launch applies a staged bundle before discovery and removes the staging copy")
    func launchAppliesStagedBundle() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bundleId = "com.example.updatepass.\(UUID().uuidString)"
        let provides: [String: Any] = ["TableProProvidesDatabaseTypeIds": ["UpdatePassDB-\(UUID().uuidString)"]]
        let installedURL = fixture.pluginsDir.appendingPathComponent("Driver.tableplugin", isDirectory: true)
        try writeBundle(at: installedURL, bundleId: bundleId, build: 1, extraInfo: provides)
        try stageUpdate(of: bundleId, build: 2, extraInfo: provides, in: fixture)
        let manager = fixture.manager

        manager.loadPlugins()
        await manager.waitForInitialLoad()

        #expect(manager.plugins.first { $0.id == bundleId }?.build == 2)
        #expect(PluginManager.bundleBuild(at: installedURL) == 2)
        let stagedDir = PluginInstaller.stagedUpdateDirectory(for: bundleId, in: fixture.pluginsDir)
        #expect(!FileManager.default.fileExists(atPath: stagedDir.path))
    }

    @Test("A staged bundle with another plugin's id is dropped and the installed copy stays")
    func mismatchedStagedBundleKeepsInstalledCopy() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let installedURL = fixture.pluginsDir.appendingPathComponent("Driver.tableplugin", isDirectory: true)
        try writeBundle(at: installedURL, bundleId: "com.example.driver", build: 1)
        try stageUpdate(of: "com.example.other", stagedAs: "com.example.driver", build: 2, in: fixture)

        PluginManager.applyStagedUpdates(in: fixture.pluginsDir)

        #expect(PluginManager.bundleBuild(at: installedURL) == 1)
        let stagedDir = PluginInstaller.stagedUpdateDirectory(for: "com.example.driver", in: fixture.pluginsDir)
        #expect(!FileManager.default.fileExists(atPath: stagedDir.path))
    }

    @Test("A staged bundle outside the PluginKit range is dropped and the installed copy stays")
    func incompatibleStagedBundleKeepsInstalledCopy() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let installedURL = fixture.pluginsDir.appendingPathComponent("Driver.tableplugin", isDirectory: true)
        try writeBundle(at: installedURL, bundleId: "com.example.driver", build: 1)
        try stageUpdate(
            of: "com.example.driver",
            build: 2,
            kit: PluginManager.currentPluginKitVersion + 1,
            in: fixture
        )

        PluginManager.applyStagedUpdates(in: fixture.pluginsDir)

        #expect(PluginManager.bundleBuild(at: installedURL) == 1)
    }

    @Test("Uninstalling a plugin drops its staged update")
    func removeStagedUpdateDropsTheCopy() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = fixture.manager
        try stageUpdate(of: "com.example.driver", build: 2, in: fixture)
        manager.stagedPluginIds = ["com.example.driver"]

        manager.removeStagedUpdate(pluginId: "com.example.driver")

        let stagedDir = PluginInstaller.stagedUpdateDirectory(for: "com.example.driver", in: fixture.pluginsDir)
        #expect(!FileManager.default.fileExists(atPath: stagedDir.path))
        #expect(manager.stagedPluginIds.isEmpty)
    }

    // MARK: - Rejected plugins

    private func kind(_ action: RejectedPluginAction) -> String {
        switch action {
        case .updateAvailable: "updateAvailable"
        case .awaitingCompatibleBuild: "awaitingCompatibleBuild"
        case .requiresAppUpdate: "requiresAppUpdate"
        case .notInRegistry: "notInRegistry"
        }
    }

    private func makeKitPlugin(kits: [Int]) -> RegistryPlugin {
        makeRegistryPlugin(releases: kits.map { makeRelease(build: 820_000 + $0, kit: $0) })
    }

    @Test("rejectedAction awaits while the manifest is still loading")
    func rejectedActionAwaitsWithoutManifest() {
        let action = PluginManager.rejectedAction(
            registryPlugin: makeKitPlugin(kits: [18]), manifestLoaded: false, kits: 18...18
        )
        #expect(kind(action) == "awaitingCompatibleBuild")
    }

    @Test("rejectedAction reports notInRegistry when no manifest entry matches")
    func rejectedActionNotInRegistry() {
        let action = PluginManager.rejectedAction(registryPlugin: nil, manifestLoaded: true, kits: 18...18)
        #expect(kind(action) == "notInRegistry")
    }

    @Test("rejectedAction offers an update when a current-kit release exists")
    func rejectedActionUpdateAvailable() {
        let action = PluginManager.rejectedAction(
            registryPlugin: makeKitPlugin(kits: [17, 18]), manifestLoaded: true, kits: 18...18
        )
        #expect(kind(action) == "updateAvailable")
    }

    @Test("rejectedAction offers an update for an older-kit release still in range")
    func rejectedActionUpdateAvailableForwardCompat() {
        let action = PluginManager.rejectedAction(
            registryPlugin: makeKitPlugin(kits: [18]), manifestLoaded: true, kits: 18...19
        )
        #expect(kind(action) == "updateAvailable")
    }

    @Test("rejectedAction asks for an app update when only a newer-kit release exists")
    func rejectedActionRequiresAppUpdate() {
        let action = PluginManager.rejectedAction(
            registryPlugin: makeKitPlugin(kits: [18, 19]), manifestLoaded: true, kits: 17...17
        )
        #expect(kind(action) == "requiresAppUpdate")
    }

    @Test("rejectedAction awaits when only pre-floor releases are published")
    func rejectedActionAwaitsForOlderKits() {
        let action = PluginManager.rejectedAction(
            registryPlugin: makeKitPlugin(kits: [16, 17]), manifestLoaded: true, kits: 18...18
        )
        #expect(kind(action) == "awaitingCompatibleBuild")
    }

    @Test("resolveRegistryId prefers the registry id from the sidecar")
    func resolveRegistryIdUsesRegistryId() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manifest = makeManifest([makeRegistryPlugin(id: "com.example.driver", releases: [])])
        let rejected = makeRejected(bundleId: "com.example.driver", registryId: "com.example.driver")

        #expect(fixture.manager.resolveRegistryId(for: rejected, manifest: manifest) == "com.example.driver")
    }

    @Test("resolveRegistryId falls back to the bundle id when the sidecar is missing")
    func resolveRegistryIdFallsBackToBundleId() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manifest = makeManifest([makeRegistryPlugin(id: "com.example.driver", releases: [])])
        let rejected = makeRejected(bundleId: "com.example.driver")

        #expect(fixture.manager.resolveRegistryId(for: rejected, manifest: manifest) == "com.example.driver")
    }

    @Test("resolveRegistryId returns nil when nothing in the manifest matches")
    func resolveRegistryIdReturnsNilForUnknown() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manifest = makeManifest([makeRegistryPlugin(id: "com.example.other", releases: [])])
        let rejected = makeRejected(bundleId: "com.example.driver")

        #expect(fixture.manager.resolveRegistryId(for: rejected, manifest: manifest) == nil)
    }

    @Test("removeFromRejected drops the entry with that URL")
    func removeFromRejectedRemovesByURL() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let rejected = makeRejected(bundleId: "com.example.driver")
        fixture.manager.rejectedPlugins = [rejected]

        fixture.manager.removeFromRejected(url: rejected.url)

        #expect(fixture.manager.rejectedPlugins.isEmpty)
    }

    @Test("Connect treats an outdated installed plugin as updatable, not missing")
    func hasOutdatedRejectedPluginMatchesType() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.manager.rejectedPlugins = [
            makeRejected(bundleId: "com.example.driver", providedDatabaseTypeIds: ["TestDriverType"])
        ]

        #expect(fixture.manager.hasOutdatedRejectedPlugin(forTypeId: "TestDriverType"))
        #expect(!fixture.manager.hasOutdatedRejectedPlugin(forTypeId: "OtherDriverType"))
    }

    @Test("A plugin rejected for another reason is not updatable")
    func hasOutdatedRejectedPluginIgnoresNonOutdated() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.manager.rejectedPlugins = [makeRejected(isOutdated: false, providedDatabaseTypeIds: ["TestDriverType"])]

        #expect(!fixture.manager.hasOutdatedRejectedPlugin(forTypeId: "TestDriverType"))
    }
}
