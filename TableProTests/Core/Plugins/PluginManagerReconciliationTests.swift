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
        isOutdated: Bool = true,
        reason: String = "ABI mismatch",
        providedDatabaseTypeIds: [String] = []
    ) -> RejectedPlugin {
        RejectedPlugin(
            url: URL(fileURLWithPath: "/tmp/test-\(UUID().uuidString).tableplugin"),
            bundleId: bundleId,
            registryId: registryId,
            name: "Test",
            reason: reason,
            isOutdated: isOutdated,
            providedDatabaseTypeIds: providedDatabaseTypeIds
        )
    }

    private func makeRegistryPlugin(id: String = "com.example.driver", kitVersions: [Int]) throws -> RegistryPlugin {
        let arch = PluginArchitecture.current.rawValue
        let binaries = kitVersions
            .map { "{\"architecture\": \"\(arch)\", \"downloadURL\": \"https://x\", \"sha256\": \"deadbeef\", \"pluginKitVersion\": \($0)}" }
            .joined(separator: ",")
        let json = """
        {
            "id": "\(id)",
            "name": "Test Plugin",
            "version": "1.0.0",
            "summary": "test",
            "author": {"name": "Tester"},
            "category": "database-driver",
            "binaries": [\(binaries)]
        }
        """
        return try JSONDecoder().decode(RegistryPlugin.self, from: Data(json.utf8))
    }

    private func kind(_ action: RejectedPluginAction) -> String {
        switch action {
        case .updateAvailable: "updateAvailable"
        case .awaitingCompatibleBuild: "awaitingCompatibleBuild"
        case .requiresAppUpdate: "requiresAppUpdate"
        case .notInRegistry: "notInRegistry"
        }
    }

    @Test("rejectedAction awaits while the manifest is still loading")
    func rejectedActionAwaitsWithoutManifest() throws {
        let plugin = try makeRegistryPlugin(kitVersions: [18])
        let action = PluginManager.rejectedAction(
            registryPlugin: plugin, manifestLoaded: false, currentKitVersion: 18, minimumKitVersion: 18
        )
        #expect(kind(action) == "awaitingCompatibleBuild")
    }

    @Test("rejectedAction reports notInRegistry when no manifest entry matches")
    func rejectedActionNotInRegistry() {
        let action = PluginManager.rejectedAction(
            registryPlugin: nil, manifestLoaded: true, currentKitVersion: 18, minimumKitVersion: 18
        )
        #expect(kind(action) == "notInRegistry")
    }

    @Test("rejectedAction offers an update when a current-kit binary exists")
    func rejectedActionUpdateAvailable() throws {
        let plugin = try makeRegistryPlugin(kitVersions: [17, 18])
        let action = PluginManager.rejectedAction(
            registryPlugin: plugin, manifestLoaded: true, currentKitVersion: 18, minimumKitVersion: 18
        )
        #expect(kind(action) == "updateAvailable")
    }

    @Test("rejectedAction offers an update for a resilient older-kit binary under a newer app")
    func rejectedActionUpdateAvailableForwardCompat() throws {
        let plugin = try makeRegistryPlugin(kitVersions: [18])
        let action = PluginManager.rejectedAction(
            registryPlugin: plugin, manifestLoaded: true, currentKitVersion: 19, minimumKitVersion: 18
        )
        #expect(kind(action) == "updateAvailable")
    }

    @Test("rejectedAction asks for an app update when only a newer-kit binary exists")
    func rejectedActionRequiresAppUpdate() throws {
        let plugin = try makeRegistryPlugin(kitVersions: [18, 19])
        let action = PluginManager.rejectedAction(
            registryPlugin: plugin, manifestLoaded: true, currentKitVersion: 17, minimumKitVersion: 17
        )
        #expect(kind(action) == "requiresAppUpdate")
    }

    @Test("rejectedAction awaits when only pre-floor binaries are published")
    func rejectedActionAwaitsForOlderKits() throws {
        let plugin = try makeRegistryPlugin(kitVersions: [16, 17])
        let action = PluginManager.rejectedAction(
            registryPlugin: plugin, manifestLoaded: true, currentKitVersion: 18, minimumKitVersion: 18
        )
        #expect(kind(action) == "awaitingCompatibleBuild")
    }

    @Test("retriggerReconciliation does nothing when no plugin is outdated")
    func retriggerReconciliationNoopWhenNoneOutdated() {
        let pm = PluginManager.shared
        let savedRejected = pm.rejectedPlugins
        let savedActive = pm.reconciliationActive
        pm.rejectedPlugins = []
        pm.reconciliationActive = false
        defer {
            pm.rejectedPlugins = savedRejected
            pm.reconciliationActive = savedActive
        }
        pm.retriggerReconciliation()
        #expect(pm.reconciliationActive == false)
    }

    @Test("ensurePluginReady returns without reconciling when the type has no outdated rejection")
    func ensurePluginReadyNoopForUnknownType() async {
        let pm = PluginManager.shared
        let savedRejected = pm.rejectedPlugins
        let savedActive = pm.reconciliationActive
        pm.rejectedPlugins = []
        pm.reconciliationActive = false
        defer {
            pm.rejectedPlugins = savedRejected
            pm.reconciliationActive = savedActive
        }
        await pm.ensurePluginReady(forTypeId: "com.example.absent")
        #expect(pm.reconciliationActive == false)
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

    @Test("connect treats an outdated installed plugin as updatable, not missing")
    func hasOutdatedRejectedPluginMatchesType() {
        let pm = PluginManager.shared
        let rejected = makeRejected(bundleId: "com.example.driver", providedDatabaseTypeIds: ["TestDriverType"])
        pm.rejectedPlugins.append(rejected)
        defer { pm.removeFromRejected(url: rejected.url) }
        #expect(pm.hasOutdatedRejectedPlugin(forTypeId: "TestDriverType"))
        #expect(!pm.hasOutdatedRejectedPlugin(forTypeId: "OtherDriverType"))
    }

    @Test("plugins rejected for non-ABI reasons are not treated as updatable")
    func hasOutdatedRejectedPluginIgnoresNonOutdated() {
        let pm = PluginManager.shared
        let rejected = makeRejected(isOutdated: false, providedDatabaseTypeIds: ["TestDriverType"])
        pm.rejectedPlugins.append(rejected)
        defer { pm.removeFromRejected(url: rejected.url) }
        #expect(!pm.hasOutdatedRejectedPlugin(forTypeId: "TestDriverType"))
    }

    @Test("outdatedReconcileReason surfaces the rejected plugin's reason for the type")
    func outdatedReconcileReasonReturnsReason() {
        let pm = PluginManager.shared
        let rejected = makeRejected(
            reason: "A newer version of TablePro is required for this plugin.",
            providedDatabaseTypeIds: ["TestDriverType"]
        )
        pm.rejectedPlugins.append(rejected)
        defer { pm.removeFromRejected(url: rejected.url) }
        #expect(pm.outdatedReconcileReason(forTypeId: "TestDriverType") == "A newer version of TablePro is required for this plugin.")
        #expect(pm.outdatedReconcileReason(forTypeId: "OtherDriverType") == nil)
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
