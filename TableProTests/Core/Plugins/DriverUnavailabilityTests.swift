//
//  DriverUnavailabilityTests.swift
//  TableProTests
//
//  An imported connection whose database type nothing answers, a plugin the user turned off and a
//  plugin that failed to load all used to surface as one message that blamed a missing plugin, so
//  the reporter installed the plugin they already had and saw nothing change.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class UnreachableRegistryProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedCount = 0

    static var requestCount: Int {
        lock.withLock { storedCount }
    }

    static func reset() {
        lock.withLock { storedCount = 0 }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.storedCount += 1 }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Driver unavailability", .serialized)
@MainActor
struct DriverUnavailabilityTests {
    private func makeManager() throws -> (manager: PluginManager, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DriverUnavailability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try #require(UserDefaults(suiteName: "DriverUnavailability.\(UUID().uuidString)"))
        let manager = PluginManager(
            userDefaults: defaults,
            builtInPluginsURL: nil,
            userPluginsDir: root.appendingPathComponent("Plugins", isDirectory: true)
        )
        manager.hasFinishedInitialLoad = true
        return (manager, root)
    }

    private func makeEntry(id: String, name: String, typeId: String, isEnabled: Bool) -> PluginEntry {
        PluginEntry(
            id: id,
            bundle: Bundle.main,
            url: URL(fileURLWithPath: "/tmp/\(id).tableplugin"),
            source: .userInstalled,
            name: name,
            version: "1.0.0",
            pluginDescription: "",
            capabilities: [.databaseDriver],
            isEnabled: isEnabled,
            databaseTypeId: typeId,
            additionalTypeIds: [],
            pluginIconName: "puzzlepiece",
            defaultPort: nil,
            exportFormatId: nil,
            importFormatId: nil,
            inspectorId: nil
        )
    }

    private func makeRejection(typeId: String, isOutdated: Bool, reason: String) -> RejectedPlugin {
        RejectedPlugin(
            url: URL(fileURLWithPath: "/tmp/rejected-\(UUID().uuidString).tableplugin"),
            bundleId: "com.example.rejected",
            registryId: nil,
            name: "Rejected Driver",
            reason: reason,
            isOutdated: isOutdated,
            providedDatabaseTypeIds: [typeId]
        )
    }

    private func makeUnreachableRegistry(root: URL) throws -> RegistryClient {
        UnreachableRegistryProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UnreachableRegistryProtocol.self]
        let defaults = try #require(UserDefaults(suiteName: "DriverUnavailabilityRegistry.\(UUID().uuidString)"))
        return RegistryClient(
            userDefaults: defaults,
            session: URLSession(configuration: config),
            manifestCacheURL: root.appendingPathComponent("registry-manifest.json")
        )
    }

    @Test("A type no plugin, curated entry or registry entry answers is unrecognized")
    func unrecognizedType() throws {
        let (manager, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        let type = DatabaseType(rawValue: "MicrosoftSQLServer")

        #expect(manager.driverUnavailability(for: type, registryManifest: nil) == .unknownType)
        #expect(ConnectionFailureClassifier.recoveryAction(for: manager.driverUnavailableError(for: type)) == .editConnection)
    }

    @Test("A type only the registry knows is installable, not unrecognized")
    func registryOnlyTypeIsNotInstalled() throws {
        let (manager, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        let typeId = "FutureDB-\(UUID().uuidString)"
        let json = """
        {
            "schemaVersion": 2,
            "plugins": [{
                "id": "com.example.future",
                "name": "Future Driver",
                "version": "1.0.0",
                "summary": "test",
                "author": {"name": "Tester"},
                "category": "database-driver",
                "databaseTypeIds": ["\(typeId)"],
                "binaries": []
            }]
        }
        """
        let manifest = try JSONDecoder().decode(RegistryManifest.self, from: Data(json.utf8))
        let type = DatabaseType(rawValue: typeId)

        #expect(manager.driverUnavailability(for: type, registryManifest: manifest) == .notInstalled)
        #expect(manager.driverUnavailability(for: type, registryManifest: nil) == .unknownType)
    }

    @Test("A plugin the user switched off is reported as off, not as missing")
    func disabledPlugin() throws {
        let (manager, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        manager.plugins = [makeEntry(id: "com.example.mssql", name: "SQL Server Driver", typeId: "SQL Server", isEnabled: false)]

        #expect(manager.driverUnavailability(for: .mssql) == .disabled(pluginId: "com.example.mssql", pluginName: "SQL Server Driver"))
    }

    @Test("An installed, enabled plugin with no driver failed to load, with the recorded reason")
    func enabledPluginThatFailedToLoad() throws {
        let (manager, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        let typeId = "LoadFailDB-\(UUID().uuidString)"
        manager.plugins = [makeEntry(id: "com.example.loadfail", name: "Load Fail", typeId: typeId, isEnabled: true)]
        manager.rejectedPlugins = [makeRejection(typeId: typeId, isOutdated: false, reason: "bad signature")]

        #expect(manager.driverUnavailability(for: DatabaseType(rawValue: typeId)) == .failedToLoad(
            pluginId: "com.example.loadfail",
            pluginName: "Load Fail",
            reason: "bad signature"
        ))
    }

    @Test("A rejected plugin that is not listed is still reported with its reason")
    func rejectedPluginWithoutAnEntry() throws {
        let (manager, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        let typeId = "RejectedDB-\(UUID().uuidString)"
        manager.rejectedPlugins = [makeRejection(typeId: typeId, isOutdated: false, reason: "failed the load gate")]

        #expect(manager.driverUnavailability(for: DatabaseType(rawValue: typeId)) == .failedToLoad(
            pluginId: "com.example.rejected",
            pluginName: "Rejected Driver",
            reason: "failed the load gate"
        ))
    }

    @Test("An outdated plugin keeps its update reason")
    func outdatedPlugin() throws {
        let (manager, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        let typeId = "OutdatedDB-\(UUID().uuidString)"
        manager.rejectedPlugins = [makeRejection(typeId: typeId, isOutdated: true, reason: "No compatible build yet")]

        #expect(manager.driverUnavailability(for: DatabaseType(rawValue: typeId)) == .outdated(reason: "No compatible build yet"))
        #expect(manager.driverUnavailableError(for: DatabaseType(rawValue: typeId)).errorDescription == "No compatible build yet")
    }

    @Test("A registry type with nothing installed is not installed")
    func registryTypeNotInstalled() throws {
        let (manager, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(manager.driverUnavailability(for: .mssql) == .notInstalled)
        #expect(ConnectionFailureClassifier.recoveryAction(for: manager.driverUnavailableError(for: .mssql)) == .installPlugin)
    }

    @Test("A bundled type whose plugin never registered failed to load, and says which")
    func bundledTypeWithoutEntry() throws {
        let (manager, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        guard case .failedToLoad(let pluginId, let pluginName, _) = manager.driverUnavailability(
            for: .mysql,
            registryManifest: nil
        ) else {
            Issue.record("Expected a bundled type with no entry to read as failed to load")
            return
        }
        #expect(pluginId == nil)
        #expect(pluginName == PluginManager.registryDisplayName(of: .mysql))
    }

    @Test("Connecting never switches a disabled plugin back on or reinstalls it")
    func connectingLeavesADisabledPluginOff() async throws {
        let (manager, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        manager.plugins = [makeEntry(id: "com.example.mssql", name: "SQL Server Driver", typeId: "SQL Server", isEnabled: false)]
        let registry = try makeUnreachableRegistry(root: root)

        try await manager.prepareForConnecting(to: .mssql, registryClient: registry)

        #expect(manager.plugins.first?.isEnabled == false)
        #expect(UnreachableRegistryProtocol.requestCount == 0)
        #expect(manager.driverUnavailability(for: .mssql) == .disabled(pluginId: "com.example.mssql", pluginName: "SQL Server Driver"))
    }

    @Test("Connecting never reinstalls a plugin that failed to load")
    func connectingLeavesAFailedPluginInPlace() async throws {
        let (manager, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        manager.plugins = [makeEntry(id: "com.example.mssql", name: "SQL Server Driver", typeId: "SQL Server", isEnabled: true)]
        manager.rejectedPlugins = [makeRejection(typeId: "SQL Server", isOutdated: false, reason: "bad signature")]
        let registry = try makeUnreachableRegistry(root: root)

        try await manager.prepareForConnecting(to: .mssql, registryClient: registry)

        #expect(UnreachableRegistryProtocol.requestCount == 0)
        #expect(manager.plugins.map(\.id) == ["com.example.mssql"])
        #expect(manager.driverUnavailableError(for: .mssql).errorDescription?.contains("SQL Server Driver") == true)
    }

    @Test("A disabled plugin's code is never loaded to answer a driver lookup")
    func disabledLazyBundleIsNeverLoaded() throws {
        let (manager, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("Disabled.tableplugin", isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let bundleId = "com.TablePro.test.disabled.\(UUID().uuidString)"
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleId,
            "CFBundleName": "Disabled",
            "CFBundleShortVersionString": "1.0.0"
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: bundleURL))
        manager.plugins = [
            PluginEntry(
                id: bundleId,
                bundle: bundle,
                url: bundleURL,
                source: .userInstalled,
                name: "Disabled",
                version: "1.0.0",
                pluginDescription: "",
                capabilities: [.databaseDriver],
                isEnabled: false,
                databaseTypeId: "DisabledDB",
                additionalTypeIds: [],
                pluginIconName: "puzzlepiece",
                defaultPort: nil,
                exportFormatId: nil,
                importFormatId: nil,
                inspectorId: nil
            )
        ]

        manager.activateLazyBundle(at: bundleURL)

        #expect(manager.rejectedPlugins.isEmpty)
        #expect(manager.driverPlugins["DisabledDB"] == nil)
    }

    @Test("A rejected bundle that declares no database types takes them from its registry entry")
    func rejectionIdentityComesFromTheRegistry() throws {
        let json = """
        {
            "schemaVersion": 2,
            "plugins": [{
                "id": "com.example.eager",
                "name": "Eager Driver",
                "version": "1.0.0",
                "summary": "test",
                "author": {"name": "Tester"},
                "category": "database-driver",
                "databaseTypeIds": ["EagerDB"],
                "binaries": []
            }]
        }
        """
        let manifest = try JSONDecoder().decode(RegistryManifest.self, from: Data(json.utf8))

        #expect(PluginManager.databaseTypeIds(of: nil, registryId: "com.example.eager", manifest: manifest) == ["EagerDB"])
        #expect(PluginManager.databaseTypeIds(of: nil, registryId: nil, manifest: manifest).isEmpty)
        #expect(PluginManager.databaseTypeIds(of: nil, registryId: "com.example.eager", manifest: nil).isEmpty)
    }

    @Test("A failed on-demand install is thrown with its own reason")
    func failedInstallSurfacesItsReason() async throws {
        let (manager, root) = try makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = try makeUnreachableRegistry(root: root)

        do {
            try await manager.prepareForConnecting(to: .mssql, registryClient: registry)
            Issue.record("Expected the on-demand install to fail against an unreachable registry")
        } catch let error as PluginError {
            guard case .pluginInstallFailed(_, let reason) = error else {
                Issue.record("Expected pluginInstallFailed, got \(error)")
                return
            }
            #expect(reason == PluginError.registryUnreachable.localizedDescription)
        }
    }
}
