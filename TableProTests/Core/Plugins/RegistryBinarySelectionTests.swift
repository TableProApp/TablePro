import Foundation
import Testing
@testable import TablePro

struct RegistryBinarySelectionTests {
    private let minimumKit = PluginManager.minimumCompatiblePluginKitVersion
    private let currentKit = PluginManager.currentPluginKitVersion

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
            RegistryBinary(architecture: .arm64, downloadURL: "https://a/current", sha256: "aaa", pluginKitVersion: currentKit),
            RegistryBinary(architecture: .arm64, downloadURL: "https://a/old", sha256: "bbb", pluginKitVersion: minimumKit - 1)
        ])
        let resolved = try plugin.resolvedBinary(for: .arm64)
        #expect(resolved.downloadURL == "https://a/current")
    }

    @Test("nil pluginKitVersion is no longer a universal fallback")
    func nilPluginKitVersionNotMatched() {
        let plugin = makePlugin(binaries: [
            RegistryBinary(architecture: .arm64, downloadURL: "https://legacy", sha256: "abc", pluginKitVersion: nil)
        ])
        #expect(throws: PluginError.self) {
            _ = try plugin.resolvedBinary(for: .arm64)
        }
    }

    @Test("valid binary is still selected when a nil-kit binary is also present (#1322 DynamoDB)")
    func validBinaryFoundAlongsideNilKit() throws {
        let plugin = makePlugin(binaries: [
            RegistryBinary(architecture: .arm64, downloadURL: "https://legacy", sha256: "abc", pluginKitVersion: nil),
            RegistryBinary(architecture: .arm64, downloadURL: "https://a/current", sha256: "def", pluginKitVersion: currentKit)
        ])
        let resolved = try plugin.resolvedBinary(for: .arm64)
        #expect(resolved.downloadURL == "https://a/current")
    }

    @Test("resilient older-kit binary is served to a newer app without re-publish")
    func forwardCompatibleBinarySelected() throws {
        let plugin = makePlugin(binaries: [
            RegistryBinary(architecture: .arm64, downloadURL: "https://a/minimum", sha256: "aaa", pluginKitVersion: minimumKit)
        ])
        let resolved = try plugin.resolvedBinary(for: .arm64)
        #expect(resolved.downloadURL == "https://a/minimum")
    }

    @Test("highest binary within the compatible range wins")
    func highestInRangeSelected() throws {
        let plugin = makePlugin(binaries: [
            RegistryBinary(architecture: .arm64, downloadURL: "https://a/minimum", sha256: "aaa", pluginKitVersion: minimumKit),
            RegistryBinary(architecture: .arm64, downloadURL: "https://a/current", sha256: "bbb", pluginKitVersion: currentKit)
        ])
        let resolved = try plugin.resolvedBinary(for: .arm64)
        #expect(resolved.downloadURL == "https://a/current")
    }

    @Test("binary below the floor is rejected")
    func belowFloorRejected() {
        let plugin = makePlugin(binaries: [
            RegistryBinary(architecture: .arm64, downloadURL: "https://a/old", sha256: "aaa", pluginKitVersion: minimumKit - 1)
        ])
        #expect(throws: PluginError.self) {
            _ = try plugin.resolvedBinary(for: .arm64)
        }
    }

    @Test("binary built for a newer app is rejected")
    func aboveCurrentRejected() {
        let plugin = makePlugin(binaries: [
            RegistryBinary(architecture: .arm64, downloadURL: "https://a/new", sha256: "aaa", pluginKitVersion: currentKit + 1)
        ])
        #expect(throws: PluginError.self) {
            _ = try plugin.resolvedBinary(for: .arm64)
        }
    }

    @Test("throws noCompatibleBinary when no arch match")
    func noArchitectureMatch() {
        let plugin = makePlugin(binaries: [
            RegistryBinary(architecture: .x86_64, downloadURL: "https://intel", sha256: "x", pluginKitVersion: currentKit)
        ])
        #expect(throws: PluginError.self) {
            _ = try plugin.resolvedBinary(for: .arm64)
        }
    }

    @Test("throws noCompatibleBinary when arch matches but no kit version match and no legacy")
    func noKitVersionMatchNoLegacy() {
        let plugin = makePlugin(binaries: [
            RegistryBinary(architecture: .arm64, downloadURL: "https://a/old", sha256: "bbb", pluginKitVersion: minimumKit - 1)
        ])
        #expect(throws: PluginError.self) {
            _ = try plugin.resolvedBinary(for: .arm64)
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

struct RegistryStaleAppTests {
    private let minimumKit = PluginManager.minimumCompatiblePluginKitVersion
    private let currentKit = PluginManager.currentPluginKitVersion

    private func makePlugin(kits: [Int]) -> RegistryPlugin {
        let payload: [String: Any] = [
            "id": "com.example.driver",
            "name": "Example",
            "version": "1.0.0",
            "summary": "test",
            "author": ["name": "Tester"],
            "category": "database-driver",
            "binaries": kits.map { kit -> [String: Any] in
                [
                    "architecture": PluginArchitecture.arm64.rawValue,
                    "downloadURL": "https://a/\(kit)",
                    "sha256": "sha\(kit)",
                    "pluginKitVersion": kit
                ]
            }
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return try! JSONDecoder().decode(RegistryPlugin.self, from: data)
    }

    // Measured on 2026-09-13: apps on kits 19 and 20 got no binary when the registry's oldest kit was 21,
    // and were told their architecture was unsupported.
    @Test("An app below every published binary is named as the stale side, not the architecture")
    func staleAppIsReportedAsStale() {
        let plugin = makePlugin(kits: [currentKit + 1, currentKit + 2])
        let expectedOldest = currentKit + 1
        let expectedAppKit = currentKit

        #expect {
            _ = try plugin.resolvedBinary(for: .arm64)
        } throws: { error in
            guard case PluginError.appTooOldForPlugin(let oldest, let appKit) = error else { return false }
            return oldest == expectedOldest && appKit == expectedAppKit
        }
    }

    @Test("A binary above the app's kit is skipped for a lower one that fits")
    func picksTheHighestBinaryTheAppCanLoad() throws {
        let plugin = makePlugin(kits: [minimumKit, currentKit, currentKit + 1])
        let resolved = try plugin.resolvedBinary(for: .arm64)

        #expect(resolved.downloadURL == "https://a/\(currentKit)")
    }

    @Test("A plugin the app is new enough for still resolves")
    func newestAppResolvesNewestBinary() throws {
        let plugin = makePlugin(kits: [minimumKit, currentKit])
        let resolved = try plugin.resolvedBinary(for: .arm64)

        #expect(resolved.downloadURL == "https://a/\(currentKit)")
    }

    @Test("A binary too old for the app is not reported as a stale app")
    func binaryBelowTheMinimumKeepsTheOriginalError() {
        let plugin = makePlugin(kits: [minimumKit - 1])

        #expect {
            _ = try plugin.resolvedBinary(for: .arm64)
        } throws: { error in
            guard case PluginError.noCompatibleBinary = error else { return false }
            return true
        }
    }

    @Test("A missing architecture is still an architecture problem")
    func missingArchitectureKeepsTheOriginalError() {
        let plugin = makePlugin(kits: [currentKit])

        #expect {
            _ = try plugin.resolvedBinary(for: .x86_64)
        } throws: { error in
            guard case PluginError.noCompatibleBinary = error else { return false }
            return true
        }
    }
}
