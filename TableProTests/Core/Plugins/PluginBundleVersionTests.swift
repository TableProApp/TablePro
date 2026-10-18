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
}
