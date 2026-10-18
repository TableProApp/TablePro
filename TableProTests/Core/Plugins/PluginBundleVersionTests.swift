import Foundation
@testable import TablePro
import Testing

struct PluginBundleVersionTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginBundleVersionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeBundle(at directory: URL, name: String, info: [String: String]) throws -> URL {
        let bundle = directory.appendingPathComponent("\(name).tableplugin", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist = info
        plist["CFBundleIdentifier"] = "com.example.\(name)"
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return bundle
    }

    @Test("bundleShortVersion reads CFBundleShortVersionString from disk")
    func readsVersionFromDisk() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bundle = try writeBundle(at: dir, name: "Driver", info: ["CFBundleShortVersionString": "1.2.3"])
        #expect(PluginManager.bundleShortVersion(at: bundle) == "1.2.3")
    }

    @Test("bundleShortVersion returns nil when the key is missing")
    func returnsNilWhenMissing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bundle = try writeBundle(at: dir, name: "Driver", info: [:])
        #expect(PluginManager.bundleShortVersion(at: bundle) == nil)
    }

    @Test("bundleShortVersion sees the new version after the bundle is replaced in place")
    func seesNewVersionAfterInPlaceReplace() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bundle = try writeBundle(at: dir, name: "Driver", info: ["CFBundleShortVersionString": "1.0.0"])

        let cached = Bundle(url: bundle)
        #expect(cached?.infoDictionary?["CFBundleShortVersionString"] as? String == "1.0.0")

        _ = try writeBundle(at: dir, name: "Driver", info: ["CFBundleShortVersionString": "2.0.0"])

        #expect(PluginManager.bundleShortVersion(at: bundle) == "2.0.0")
        #expect(Bundle(url: bundle)?.infoDictionary?["CFBundleShortVersionString"] as? String == "1.0.0")
    }

    @Test("bundleBuild reads CFBundleVersion from disk")
    func readsBuildFromDisk() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bundle = try writeBundle(at: dir, name: "Driver", info: ["CFBundleVersion": "820099"])
        #expect(PluginManager.bundleBuild(at: bundle) == 820_099)
    }

    @Test("bundleBuild is 0 when CFBundleVersion is not an integer", arguments: ["1.2", "abc", ""])
    func buildIsZeroWhenNotAnInteger(value: String) throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bundle = try writeBundle(at: dir, name: "Driver", info: ["CFBundleVersion": value])
        #expect(PluginManager.bundleBuild(at: bundle) == 0)
    }

    @Test("bundleBuild is 0 when CFBundleVersion is missing")
    func buildIsZeroWhenMissing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bundle = try writeBundle(at: dir, name: "Driver", info: [:])
        #expect(PluginManager.bundleBuild(at: bundle) == 0)
    }

    @Test("bundleBuild is 0 when there is no bundle on disk")
    func buildIsZeroWithoutBundle() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(PluginManager.bundleBuild(at: dir.appendingPathComponent("Missing.tableplugin")) == 0)
    }

    @Test("bundleBuild sees the new build after the bundle is replaced in place")
    func seesNewBuildAfterInPlaceReplace() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bundle = try writeBundle(at: dir, name: "Driver", info: ["CFBundleVersion": "820001"])
        #expect(Bundle(url: bundle)?.infoDictionary?["CFBundleVersion"] as? String == "820001")

        _ = try writeBundle(at: dir, name: "Driver", info: ["CFBundleVersion": "820099"])

        #expect(PluginManager.bundleBuild(at: bundle) == 820_099)
    }
}
