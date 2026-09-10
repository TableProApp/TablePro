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
        manager.plugins = [try entry(id: "com.example.unsigned", url: url)]

        manager.withdrawPlugin(at: url, reason: PluginError.signatureInvalid(detail: "bundle is not signed"))

        XCTAssertTrue(manager.plugins.isEmpty)
        XCTAssertNil(manager.lazyDriverURLs["ExampleDB"])
        XCTAssertEqual(manager.rejectedPlugins.count, 1)
    }

    /// Two bundles can declare the same driver key, and the one registered last owns it. Deleting
    /// the withdrawn bundle's keys by URL would take the shared key with it, leaving the valid
    /// plugin listed but impossible to activate.
    func testWithdrawingRestoresAKeyAnotherPluginAlsoDeclares() throws {
        let goodURL = try makeBundle(id: "com.example.good", databaseTypeIds: ["ExampleDB"])
        let badURL = try makeBundle(id: "com.example.bad", databaseTypeIds: ["ExampleDB"])
        manager.plugins = [
            try entry(id: "com.example.good", url: goodURL),
            try entry(id: "com.example.bad", url: badURL)
        ]

        manager.withdrawPlugin(at: badURL, reason: PluginError.signatureInvalid(detail: "bundle is not signed"))

        XCTAssertEqual(manager.plugins.map(\.id), ["com.example.good"])
        XCTAssertEqual(manager.lazyDriverURLs["ExampleDB"], goodURL)
    }

    private func entry(id: String, url: URL) throws -> PluginEntry {
        PluginEntry(
            id: id,
            bundle: try XCTUnwrap(Bundle(url: url)),
            url: url,
            source: .userInstalled,
            name: id,
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
        )
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
