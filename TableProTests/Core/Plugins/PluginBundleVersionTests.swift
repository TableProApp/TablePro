//
//  PluginBundleVersionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Plugin bundle version reading", .serialized)
struct PluginBundleVersionTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginBundleVersionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeBundle(at directory: URL, name: String, version: String) throws -> URL {
        let bundle = directory.appendingPathComponent("\(name).tableplugin", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let payload = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key><string>com.example.\(name)</string>
            <key>CFBundleShortVersionString</key><string>\(version)</string>
        </dict>
        </plist>
        """
        try payload.write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        return bundle
    }

    @Test("bundleShortVersion reads CFBundleShortVersionString from disk")
    func readsVersionFromDisk() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bundle = try writeBundle(at: dir, name: "Driver", version: "1.2.3")
        #expect(PluginManager.bundleShortVersion(at: bundle) == "1.2.3")
    }

    @Test("bundleShortVersion returns nil when the key is missing")
    func returnsNilWhenMissing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bundle = dir.appendingPathComponent("Driver.tableplugin", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let payload = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict><key>CFBundleIdentifier</key><string>com.example.Driver</string></dict>
        </plist>
        """
        try payload.write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)

        #expect(PluginManager.bundleShortVersion(at: bundle) == nil)
    }

    @Test("bundleShortVersion sees the new version after the bundle is replaced in place")
    func seesNewVersionAfterInPlaceReplace() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bundle = try writeBundle(at: dir, name: "Driver", version: "1.0.0")

        let cached = Bundle(url: bundle)
        #expect(cached?.infoDictionary?["CFBundleShortVersionString"] as? String == "1.0.0")

        _ = try writeBundle(at: dir, name: "Driver", version: "2.0.0")

        #expect(PluginManager.bundleShortVersion(at: bundle) == "2.0.0")
        #expect(Bundle(url: bundle)?.infoDictionary?["CFBundleShortVersionString"] as? String == "1.0.0")
    }
}
