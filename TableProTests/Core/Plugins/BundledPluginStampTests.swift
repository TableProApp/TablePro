import Foundation
@testable import TablePro
import Testing

struct BundledPluginStampTests {
    private struct StampedPlugin {
        let name: String
        let info: [String: Any]
    }

    private static func bundledPlugins() throws -> [StampedPlugin] {
        let plugIns = try #require(Bundle.main.builtInPlugInsURL)
        let bundles = try FileManager.default.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "tableplugin" }
        return try bundles.map { bundle in
            let data = try Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
            let info = try #require(plist as? [String: Any], "\(bundle.lastPathComponent) has no Info.plist dictionary")
            return StampedPlugin(name: bundle.lastPathComponent, info: info)
        }
    }

    @Test("Every bundled plugin declares the app's PluginKit version as an integer")
    func bundledPluginsCarryTheAppKit() throws {
        let plugins = try Self.bundledPlugins()
        #expect(!plugins.isEmpty)
        for plugin in plugins {
            let declared = plugin.info["TableProPluginKitVersion"]
            #expect(
                declared as? Int == PluginManager.currentPluginKitVersion,
                "\(plugin.name) declares \(String(describing: declared)), the app is \(PluginManager.currentPluginKitVersion)"
            )
        }
    }

    @Test("The app's PluginKit range is stamped from the build setting")
    func appKitRangeIsOrdered() {
        #expect(PluginManager.minimumCompatiblePluginKitVersion > 0)
        #expect(PluginManager.minimumCompatiblePluginKitVersion <= PluginManager.currentPluginKitVersion)
    }
}
