//
//  PluginManagerReconciliationTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

@Suite("PluginManager reconciliation helpers", .serialized)
@MainActor
struct PluginManagerReconciliationTests {

    private func makeManifest(pluginIds: [String]) -> RegistryManifest {
        let plugins = pluginIds.map { id -> RegistryPlugin in
            let json = """
            {
                "id": "\(id)",
                "name": "Test Plugin",
                "version": "1.0.0",
                "summary": "test",
                "author": {"name": "Tester"},
                "category": "database-driver",
                "binaries": [
                    {"architecture": "arm64", "downloadURL": "https://x", "sha256": "deadbeef", "pluginKitVersion": 13}
                ]
            }
            """
            return try! JSONDecoder().decode(RegistryPlugin.self, from: Data(json.utf8))
        }
        return RegistryManifest(schemaVersion: 2, plugins: plugins)
    }

    private func makeRejected(
        bundleId: String? = nil,
        registryId: String? = nil,
        isOutdated: Bool = true
    ) -> RejectedPlugin {
        RejectedPlugin(
            url: URL(fileURLWithPath: "/tmp/test-\(UUID().uuidString).tableplugin"),
            bundleId: bundleId,
            registryId: registryId,
            name: "Test",
            reason: "ABI mismatch",
            isOutdated: isOutdated
        )
    }

    @Test("resolveRegistryId prefers explicit registryId from sidecar")
    func resolveRegistryIdUsesRegistryId() {
        let pm = PluginManager.shared
        let manifest = makeManifest(pluginIds: ["com.example.driver"])
        let rejected = makeRejected(bundleId: "com.example.driver", registryId: "com.example.driver")
        let resolved = pm.resolveRegistryId(for: rejected, manifest: manifest)
        #expect(resolved == "com.example.driver")
    }

    @Test("resolveRegistryId falls back to bundleId when sidecar missing")
    func resolveRegistryIdFallsBackToBundleId() {
        let pm = PluginManager.shared
        let manifest = makeManifest(pluginIds: ["com.example.driver"])
        let rejected = makeRejected(bundleId: "com.example.driver", registryId: nil)
        let resolved = pm.resolveRegistryId(for: rejected, manifest: manifest)
        #expect(resolved == "com.example.driver")
    }

    @Test("resolveRegistryId returns nil when no match in manifest")
    func resolveRegistryIdReturnsNilForUnknown() {
        let pm = PluginManager.shared
        let manifest = makeManifest(pluginIds: ["com.example.other"])
        let rejected = makeRejected(bundleId: "com.example.driver", registryId: nil)
        let resolved = pm.resolveRegistryId(for: rejected, manifest: manifest)
        #expect(resolved == nil)
    }

    @Test("removeFromRejected drops entries with matching URL")
    func removeFromRejectedRemovesByURL() {
        let pm = PluginManager.shared
        let rejected = makeRejected(bundleId: "com.example.driver", registryId: "com.example.driver")
        pm.rejectedPlugins.append(rejected)
        let url = rejected.url
        pm.removeFromRejected(url: url)
        #expect(!pm.rejectedPlugins.contains { $0.url == url })
    }

    @Test("incompatible-build errors are permanent reconciliation failures")
    func permanentFailuresClassified() {
        #expect(PluginError.noCompatibleBinary.isPermanentReconciliationFailure)
        #expect(PluginError.incompatibleVersion(required: 15, current: 14).isPermanentReconciliationFailure)
        #expect(PluginError.incompatibleWithCurrentApp(minimumRequired: "0.44.0").isPermanentReconciliationFailure)
        #expect(PluginError.appVersionTooOld(minimumRequired: "0.44.0", currentApp: "0.43.3").isPermanentReconciliationFailure)
    }

    @Test("transient errors are retried, not surfaced as permanent failures")
    func transientFailuresNotPermanent() {
        #expect(!PluginError.downloadFailed("timeout").isPermanentReconciliationFailure)
        #expect(!PluginError.checksumMismatch.isPermanentReconciliationFailure)
        #expect(!PluginError.installFailed("io error").isPermanentReconciliationFailure)
    }

    @Test("reconciliation retries only when a transient failure still has attempts left")
    func reconciliationRetryDecision() {
        #expect(PluginManager.reconciliationShouldRetry(sawTransientFailure: true, retryRemaining: true))
        #expect(!PluginManager.reconciliationShouldRetry(sawTransientFailure: true, retryRemaining: false))
        #expect(!PluginManager.reconciliationShouldRetry(sawTransientFailure: false, retryRemaining: true))
        #expect(!PluginManager.reconciliationShouldRetry(sawTransientFailure: false, retryRemaining: false))
    }

    @Test("forceRefresh manifest request bypasses the local cache and sends no If-None-Match")
    func forceRefreshRequestBypassesCache() {
        let request = RegistryClient.shared.makeManifestRequest(forceRefresh: true)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
    }
}
