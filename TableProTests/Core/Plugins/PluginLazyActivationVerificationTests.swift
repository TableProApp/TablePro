//
//  PluginLazyActivationVerificationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Plugin lazy activation re-verification", .serialized)
@MainActor
struct PluginLazyActivationVerificationTests {
    @Test("user-installed lazy bundle that fails the signature re-check is rejected, never loaded")
    func rejectsTamperedUserInstalledBundleBeforeLoad() throws {
        guard ProcessInfo.processInfo.environment["TABLEPRO_ALLOW_UNSIGNED_PLUGINS"] != "1" else { return }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("LazyActivation-\(UUID().uuidString)", isDirectory: true)
        let userPluginsDir = root.appendingPathComponent("Plugins", isDirectory: true)
        let bundleURL = userPluginsDir.appendingPathComponent("Tampered.tableplugin", isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try fm.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let bundleId = "com.TablePro.test.tampered.\(UUID().uuidString)"
        let typeId = "tampered-db-\(UUID().uuidString)"
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleId,
            "CFBundleName": "Tampered",
            "CFBundleShortVersionString": "1.0.0"
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))

        let suiteName = "LazyActivationTest.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = PluginManager(userDefaults: defaults, builtInPluginsURL: nil, userPluginsDir: userPluginsDir)
        let bundle = try #require(Bundle(url: bundleURL))
        manager.plugins = [
            PluginEntry(
                id: bundleId,
                bundle: bundle,
                url: bundleURL,
                source: .userInstalled,
                name: "Tampered",
                version: "1.0.0",
                pluginDescription: "",
                capabilities: [.databaseDriver],
                isEnabled: true,
                databaseTypeId: typeId,
                additionalTypeIds: [],
                pluginIconName: "puzzlepiece",
                defaultPort: nil,
                exportFormatId: nil,
                importFormatId: nil,
                inspectorId: nil
            )
        ]

        manager.activateLazyBundle(at: bundleURL)

        #expect(manager.driverPlugins[typeId] == nil)
        #expect(manager.rejectedPlugins.contains { $0.url == bundleURL })
        #expect(manager.rejectedPlugins.filter { $0.url == bundleURL }.count == 1)

        manager.activateLazyBundle(at: bundleURL)

        #expect(manager.driverPlugins[typeId] == nil)
        #expect(manager.rejectedPlugins.filter { $0.url == bundleURL }.count == 1)
    }

    @Test("lazy bundle whose executable fails to load is rejected with a specific reason")
    func rejectsBundleThatFailsToLoad() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("LazyLoadFail-\(UUID().uuidString)", isDirectory: true)
        let userPluginsDir = root.appendingPathComponent("Plugins", isDirectory: true)
        let bundleURL = userPluginsDir.appendingPathComponent("Broken.tableplugin", isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let macosURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        try fm.createDirectory(at: macosURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let bundleId = "com.TablePro.test.broken.\(UUID().uuidString)"
        let typeId = "broken-db-\(UUID().uuidString)"
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleId,
            "CFBundleName": "Broken",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleExecutable": "Broken"
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))
        try Data("not a mach-o binary".utf8).write(to: macosURL.appendingPathComponent("Broken"))

        let suiteName = "LazyLoadFailTest.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = PluginManager(userDefaults: defaults, builtInPluginsURL: nil, userPluginsDir: userPluginsDir)
        let bundle = try #require(Bundle(url: bundleURL))
        manager.plugins = [
            PluginEntry(
                id: bundleId,
                bundle: bundle,
                url: bundleURL,
                source: .builtIn,
                name: "Broken",
                version: "1.0.0",
                pluginDescription: "",
                capabilities: [.databaseDriver],
                isEnabled: true,
                databaseTypeId: typeId,
                additionalTypeIds: [],
                pluginIconName: "puzzlepiece",
                defaultPort: nil,
                exportFormatId: nil,
                importFormatId: nil,
                inspectorId: nil
            )
        ]

        manager.activateLazyBundle(at: bundleURL)

        #expect(manager.driverPlugins[typeId] == nil)
        let rejection = try #require(manager.rejectedPlugins.first { $0.url == bundleURL })
        #expect(!rejection.reason.isEmpty)
        #expect(!rejection.reason.contains("Bundle failed to load executable"))

        manager.activateLazyBundle(at: bundleURL)
        #expect(manager.rejectedPlugins.filter { $0.url == bundleURL }.count == 1)
    }
}
