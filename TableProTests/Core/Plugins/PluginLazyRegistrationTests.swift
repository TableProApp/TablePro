import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct PluginLazyRegistrationTests {
    private struct Fixture {
        let manager: PluginManager
        let pluginsDir: URL
        let root: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginLazyRegistrationTests-\(UUID().uuidString)", isDirectory: true)
        let pluginsDir = root.appendingPathComponent("Plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        let manager = PluginManager(builtInPluginsURL: nil, userPluginsDir: pluginsDir)
        return Fixture(manager: manager, pluginsDir: pluginsDir, root: root)
    }

    // The executable is not Mach-O, so any attempt to load the bundle fails and is recorded.
    @discardableResult
    private func makeOracleDriver(in pluginsDir: URL, provides: [String: [String]]) throws -> URL {
        let url = pluginsDir.appendingPathComponent("OracleDriver.tableplugin", isDirectory: true)
        let macOS = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try Data("not a mach-o binary".utf8).write(to: macOS.appendingPathComponent("OracleDriver"))
        var info: [String: Any] = [
            "CFBundleIdentifier": "com.TablePro.OracleDriver",
            "CFBundleExecutable": "OracleDriver",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "TableProPluginKitVersion": PluginManager.currentPluginKitVersion
        ]
        info.merge(provides) { _, new in new }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
        return url
    }

    @Test("A driver whose Info.plist declares its database type ids registers at launch without loading")
    func stampedDriverRegistersWithoutLoading() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let url = try makeOracleDriver(
            in: fixture.pluginsDir,
            provides: ["TableProProvidesDatabaseTypeIds": [DatabaseType.oracle.rawValue]]
        )
        let manager = fixture.manager

        manager.loadPlugins()
        await manager.waitForInitialLoad()

        // Discovery reports the folder under /private/var, so compare the bundle, not the path.
        #expect(manager.lazyDriverURLs[DatabaseType.oracle.rawValue]?.lastPathComponent == url.lastPathComponent)
        #expect(manager.isDriverInstalled(for: .oracle))
        #expect(manager.driverPlugins[DatabaseType.oracle.rawValue] == nil)
        #expect(manager.plugins.first { $0.id == "com.TablePro.OracleDriver" }?.databaseTypeId == DatabaseType.oracle.rawValue)
        #expect(manager.rejectedPlugins.isEmpty)
    }

    @Test("A driver whose Info.plist declares no ids is loaded at launch")
    func unstampedDriverLoadsAtLaunch() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try makeOracleDriver(in: fixture.pluginsDir, provides: [:])
        let manager = fixture.manager

        manager.loadPlugins()
        await manager.waitForInitialLoad()

        #expect(manager.lazyDriverURLs.isEmpty)
        #expect(!manager.isDriverInstalled(for: .oracle))
        #expect(manager.rejectedPlugins.map { $0.bundleId } == ["com.TablePro.OracleDriver"])
    }

    @Test("Every bundled plugin's Info.plist declares the ids its class provides, primary id first")
    func bundledPluginsDeclareWhatTheyProvide() throws {
        let plugIns = try #require(Bundle.main.builtInPlugInsURL)
        let urls = try FileManager.default.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "tableplugin" }
        #expect(!urls.isEmpty)

        for url in urls {
            let bundle = try #require(Bundle(url: url))
            let manifest = try #require(PluginManifest(bundle: bundle))
            let name = url.lastPathComponent
            #expect(manifest.supportsLazyLoad, "\(name) declares no TableProProvides* key")

            let principal: AnyClass? = bundle.principalClass
            let driver = principal as? any DriverPlugin.Type
            let exporter = principal as? any ExportFormatPlugin.Type
            let importer = principal as? any ImportFormatPlugin.Type
            #expect(driver != nil || exporter != nil || importer != nil, "\(name) has no plugin principal class")

            let driverIds = driver.map { [$0.databaseTypeId] + $0.additionalDatabaseTypeIds } ?? []
            #expect(manifest.providedDatabaseTypeIds == driverIds, "\(name)")
            #expect(manifest.providedExportFormatIds == (exporter.map { [$0.formatId] } ?? []), "\(name)")
            #expect(manifest.providedImportFormatIds == (importer.map { [$0.formatId] } ?? []), "\(name)")
        }
    }
}
