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
        let resolved = try plugin.resolvedBinary(for: .arm64, pluginKitVersion: 13)
        #expect(resolved.downloadURL == "https://a/13")
    }

    @Test("nil pluginKitVersion is no longer a universal fallback")
    func nilPluginKitVersionNotMatched() {
        let plugin = makePlugin(binaries: [
            RegistryBinary(architecture: .arm64, downloadURL: "https://legacy", sha256: "abc", pluginKitVersion: nil)
        ])
        #expect(throws: PluginError.self) {
            _ = try plugin.resolvedBinary(for: .arm64, pluginKitVersion: 13)
        }
    }

    @Test("throws noCompatibleBinary when no arch match")
    func noArchitectureMatch() {
        let plugin = makePlugin(binaries: [
            RegistryBinary(architecture: .x86_64, downloadURL: "https://intel", sha256: "x", pluginKitVersion: 13)
        ])
        #expect(throws: PluginError.self) {
            _ = try plugin.resolvedBinary(for: .arm64, pluginKitVersion: 13)
        }
    }

    @Test("throws noCompatibleBinary when arch matches but no kit version match and no legacy")
    func noKitVersionMatchNoLegacy() {
        let plugin = makePlugin(binaries: [
            RegistryBinary(architecture: .arm64, downloadURL: "https://a/12", sha256: "bbb", pluginKitVersion: 12)
        ])
        #expect(throws: PluginError.self) {
            _ = try plugin.resolvedBinary(for: .arm64, pluginKitVersion: 13)
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
