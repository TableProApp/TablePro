import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

private final class ManifestStubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var bodies: [URL: Data] = [:]
    nonisolated(unsafe) private static var requests: [URL: Int] = [:]

    static func serve(_ body: Data, at url: URL) {
        lock.withLock { bodies[url] = body }
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
        let body = Self.lock.withLock {
            Self.requests[url, default: 0] += 1
            return Self.bodies[url] ?? Data()
        }
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

    init(installGate: AsyncGate? = nil, stageGate: AsyncGate? = nil) {
        self.installGate = installGate
        self.stageGate = stageGate
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
        return try writeBundle(at: url, bundleId: registryPlugin.id, build: release.build)
    }
}

@Suite("Plugin registry update pass", .serialized)
@MainActor
struct PluginRegistryUpdatePassTests {
    private struct Fixture {
        let manager: PluginManager
        let pluginsDir: URL
        let root: URL
    }

    private func makeFixture(
        installer: any RegistryPluginInstalling = PluginInstaller.shared
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginRegistryUpdatePassTests-\(UUID().uuidString)", isDirectory: true)
        let pluginsDir = root.appendingPathComponent("Plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        let manager = PluginManager(builtInPluginsURL: nil, userPluginsDir: pluginsDir, registryInstaller: installer)
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
            iconName: nil,
            databaseTypeIds: nil,
            exportFormatIds: nil,
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

    private func makeRegistryClient(
        servingBuild build: Int,
        pluginIds: [String] = ["com.example.driver"]
    ) throws -> (client: RegistryClient, manifestURL: URL) {
        let manifestURL = try #require(URL(string: "https://registry.invalid/\(UUID().uuidString)/plugins/v3.json"))
        let plugins = pluginIds.map { id in
            """
            {"id": "\(id)", "name": "Driver", "releases": [{
                "version": "1.0", "build": \(build), "channel": "stable",
                "pluginKit": \(PluginManager.currentPluginKitVersion),
                "minimumSystemVersion": "13.0", "url": "https://x", "sha256": "deadbeef"
            }]}
            """
        }
        ManifestStubProtocol.serve(Data("""
        {"schemaVersion": 3, "retainFromPluginKit": 39, "plugins": [\(plugins.joined(separator: ","))]}
        """.utf8), at: manifestURL)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ManifestStubProtocol.self]
        let client = RegistryClient(manifestURL: manifestURL, session: URLSession(configuration: configuration))
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

    @Test("A file staged over a loaded registry plugin drops its sidecar, so the pass leaves it alone")
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

        _ = try manager.stageForNextLaunch(bundleAt: file, replacing: entry)

        #expect(manager.stagedPluginIds == [entry.id])
        #expect(PluginManager.readRegistryMetadata(for: entry.url) == nil)
        manager.stagedPluginIds = []
        #expect(manager.registryUpdateTargets(appBuild: 20).isEmpty)
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
