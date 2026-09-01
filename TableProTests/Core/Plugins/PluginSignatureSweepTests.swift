//
//  PluginSignatureSweepTests.swift
//  TableProTests
//

@testable import TablePro
import TableProPluginKit
import XCTest

@MainActor
final class PluginSignatureSweepTests: XCTestCase {
    private var root: URL!
    private var manager: PluginManager!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginSignatureSweepTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        manager = PluginManager(
            userDefaults: UserDefaults(suiteName: "PluginSignatureSweepTests-\(UUID().uuidString)") ?? .standard,
            builtInPluginsURL: nil,
            userPluginsDir: root.appendingPathComponent("Plugins", isDirectory: true)
        )
    }

    override func tearDown() async throws {
        manager = nil
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        try await super.tearDown()
    }

    /// An ad-hoc signed bundle is not first-party and carries no Developer ID, which is what the
    /// sweep is looking for. A test fixture cannot be signed at all, which fails the same way.
    func testSweepRejectsAnUnsignedBundleAndWithdrawsIt() async throws {
        let url = try makeBundle(id: "com.example.unsigned", databaseTypeIds: ["ExampleDB"])
        manager.pendingSignatureChecks = [url]

        await manager.sweepPluginSignatures()

        XCTAssertEqual(manager.rejectedPlugins.count, 1)
        XCTAssertEqual(manager.rejectedPlugins.first?.url, url)
        XCTAssertEqual(manager.rejectedPlugins.first?.bundleId, "com.example.unsigned")
        XCTAssertTrue(manager.pendingSignatureChecks.isEmpty)
    }

    func testSweepRecordsARejectionOnlyOncePerBundle() async throws {
        let url = try makeBundle(id: "com.example.unsigned", databaseTypeIds: ["ExampleDB"])

        manager.pendingSignatureChecks = [url]
        await manager.sweepPluginSignatures()
        manager.pendingSignatureChecks = [url]
        await manager.sweepPluginSignatures()

        XCTAssertEqual(manager.rejectedPlugins.count, 1)
    }

    func testSweepWithNothingPendingRecordsNothing() async {
        await manager.sweepPluginSignatures()

        XCTAssertTrue(manager.rejectedPlugins.isEmpty)
    }

    /// A bundle the sweep rejects must stop being offered, or the app would list a driver it will
    /// refuse to activate.
    func testWithdrawingRemovesTheEntryAndItsLazyDriverRegistration() throws {
        let url = try makeBundle(id: "com.example.unsigned", databaseTypeIds: ["ExampleDB"])
        let bundle = try XCTUnwrap(Bundle(url: url))
        manager.plugins = [PluginEntry(
            id: "com.example.unsigned",
            bundle: bundle,
            url: url,
            source: .userInstalled,
            name: "Example",
            version: "1.0",
            pluginDescription: "",
            capabilities: [.databaseDriver],
            isEnabled: true,
            databaseTypeId: "ExampleDB",
            additionalTypeIds: [],
            pluginIconName: "puzzlepiece",
            defaultPort: nil,
            exportFormatId: nil,
            importFormatId: nil,
            inspectorId: nil
        )]

        manager.withdrawPlugin(at: url, reason: PluginError.signatureInvalid(detail: "bundle is not signed"))

        XCTAssertTrue(manager.plugins.isEmpty)
        XCTAssertNil(manager.lazyDriverURLs["ExampleDB"])
        XCTAssertEqual(manager.rejectedPlugins.count, 1)
    }

    private func makeBundle(id: String, databaseTypeIds: [String]) throws -> URL {
        let url = root.appendingPathComponent("\(id).tableplugin", isDirectory: true)
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": id,
            "CFBundleName": id,
            "CFBundleShortVersionString": "1.0",
            "TableProPluginKitVersion": PluginManager.currentPluginKitVersion,
            "TableProProvidesDatabaseTypeIds": databaseTypeIds
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return url
    }
}
