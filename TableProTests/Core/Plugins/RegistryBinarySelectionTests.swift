//
//  RegistryBinarySelectionTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

@Suite("RegistryPlugin.resolvedBinary v2 selection")
struct RegistryBinarySelectionTests {

    private func makePlugin(binaries: [RegistryBinary]) -> RegistryPlugin {
        let payload: [String: Any] = [
            "id": "com.example.driver",
            "name": "Example",
            "version": "1.0.0",
            "summary": "test",
            "author": ["name": "Tester"],
            "category": "database-driver",
            "binaries": binaries.map { binary -> [String: Any] in
                var dict: [String: Any] = [
                    "architecture": binary.architecture.rawValue,
                    "downloadURL": binary.downloadURL,
                    "sha256": binary.sha256
                ]
                if let kit = binary.pluginKitVersion { dict["pluginKitVersion"] = kit }
                return dict
            }
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return try! JSONDecoder().decode(RegistryPlugin.self, from: data)
    }

    @Test("exact pluginKitVersion + arch match wins")
    func exactMatchSelected() throws {
        let plugin = makePlugin(binaries: [
            RegistryBinary(architecture: .arm64, downloadURL: "https://a/13", sha256: "aaa", pluginKitVersion: 13),
            RegistryBinary(architecture: .arm64, downloadURL: "https://a/12", sha256: "bbb", pluginKitVersion: 12)
        ])
        let resolved = try plugin.resolvedBinary(for: .arm64, currentKitVersion: 13, minimumKitVersion: 13)
        #expect(resolved.downloadURL == "https://a/13")
    }

    @Test("nil pluginKitVersion is no longer a universal fallback")
    func nilPluginKitVersionNotMatched() {
        let plugin = makePlugin(binaries: [
            RegistryBinary(architecture: .arm64, downloadURL: "https://legacy", sha256: "abc", pluginKitVersion: nil)
        ])
        #expect(throws: PluginError.self) {
            _ = try plugin.resolvedBinary(for: .arm64, currentKitVersion: 13, minimumKitVersion: 13)
        }
    }

    @Test("valid binary is still selected when a nil-kit binary is also present (#1322 DynamoDB)")
    func validBinaryFoundAlongsideNilKit() throws {
        let plugin = makePlugin(binaries: [
            RegistryBinary(architecture: .arm64, downloadURL: "https://legacy", sha256: "abc", pluginKitVersion: nil),
            RegistryBinary(architecture: .arm64, downloadURL: "https://a/14", sha256: "def", pluginKitVersion: 14)
        ])
        let resolved = try plugin.resolvedBinary(for: .arm64, currentKitVersion: 14, minimumKitVersion: 14)
        #expect(resolved.downloadURL == "https://a/14")
    }

    @Test("resilient older-kit binary is served to a newer app without re-publish")
    func forwardCompatibleBinarySelected() throws {
        let plugin = makePlugin(binaries: [
            RegistryBinary(architecture: .arm64, downloadURL: "https://a/18", sha256: "aaa", pluginKitVersion: 18)
        ])
        let resolved = try plugin.resolvedBinary(for: .arm64, currentKitVersion: 19, minimumKitVersion: 18)
        #expect(resolved.downloadURL == "https://a/18")
    }

    @Test("highest binary within the compatible range wins")
    func highestInRangeSelected() throws {
        let plugin = makePlugin(binaries: [
            RegistryBinary(architecture: .arm64, downloadURL: "https://a/18", sha256: "aaa", pluginKitVersion: 18),
            RegistryBinary(architecture: .arm64, downloadURL: "https://a/19", sha256: "bbb", pluginKitVersion: 19),
            RegistryBinary(architecture: .arm64, downloadURL: "https://a/20", sha256: "ccc", pluginKitVersion: 20)
        ])
        let resolved = try plugin.resolvedBinary(for: .arm64, currentKitVersion: 20, minimumKitVersion: 18)
        #expect(resolved.downloadURL == "https://a/20")
    }

    @Test("binary below the floor is rejected")
    func belowFloorRejected() {
        let plugin = makePlugin(binaries: [
            RegistryBinary(architecture: .arm64, downloadURL: "https://a/17", sha256: "aaa", pluginKitVersion: 17)
        ])
        #expect(throws: PluginError.self) {
            _ = try plugin.resolvedBinary(for: .arm64, currentKitVersion: 18, minimumKitVersion: 18)
        }
    }

    @Test("binary built for a newer app is rejected")
    func aboveCurrentRejected() {
        let plugin = makePlugin(binaries: [
            RegistryBinary(architecture: .arm64, downloadURL: "https://a/19", sha256: "aaa", pluginKitVersion: 19)
        ])
        #expect(throws: PluginError.self) {
            _ = try plugin.resolvedBinary(for: .arm64, currentKitVersion: 18, minimumKitVersion: 18)
        }
    }

    @Test("throws noCompatibleBinary when no arch match")
    func noArchitectureMatch() {
        let plugin = makePlugin(binaries: [
            RegistryBinary(architecture: .x86_64, downloadURL: "https://intel", sha256: "x", pluginKitVersion: 13)
        ])
        #expect(throws: PluginError.self) {
            _ = try plugin.resolvedBinary(for: .arm64, currentKitVersion: 13, minimumKitVersion: 13)
        }
    }

    @Test("throws noCompatibleBinary when arch matches but no kit version match and no legacy")
    func noKitVersionMatchNoLegacy() {
        let plugin = makePlugin(binaries: [
            RegistryBinary(architecture: .arm64, downloadURL: "https://a/12", sha256: "bbb", pluginKitVersion: 12)
        ])
        #expect(throws: PluginError.self) {
            _ = try plugin.resolvedBinary(for: .arm64, currentKitVersion: 13, minimumKitVersion: 13)
        }
    }

    @Test("v1 manifest with flat downloadURL/sha256 decodes to arm64 + x86_64 binaries")
    func v1FlatFieldsBackwardCompat() throws {
        let json = #"""
        {
          "id": "com.example.legacy",
          "name": "Legacy",
          "version": "1.0.0",
          "summary": "v1 entry",
          "author": {"name": "Tester"},
          "category": "database-driver",
          "downloadURL": "https://legacy.example/plugin.zip",
          "sha256": "deadbeef",
          "minPluginKitVersion": 11
        }
        """#
        let plugin = try JSONDecoder().decode(RegistryPlugin.self, from: Data(json.utf8))
        #expect(plugin.binaries.count == 2)
        #expect(plugin.binaries.contains { $0.architecture == .arm64 && $0.pluginKitVersion == 11 })
        #expect(plugin.binaries.contains { $0.architecture == .x86_64 && $0.pluginKitVersion == 11 })
    }
}
