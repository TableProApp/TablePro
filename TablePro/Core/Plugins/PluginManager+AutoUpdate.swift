//
//  PluginManager+AutoUpdate.swift
//  TablePro
//

import Combine
import Foundation
import os

private enum ReconciliationConfig {
    static let maxAttempts = 3
    static let firstRetryDelay: Duration = .seconds(30)
    static let secondRetryDelay: Duration = .seconds(300)
}

extension PluginManager {
    func scheduleReconciliation() {
        reconciliationTask?.cancel()
        reconciliationTask = Task { [weak self] in
            await self?.runReconciliationLoop()
        }
    }

    func runReconciliationLoop() async {
        let outdated = rejectedPlugins.filter(\.isOutdated)
        guard !outdated.isEmpty else {
            emitReconciliationOutcome()
            refreshRegistryUpdateSet()
            return
        }

        await RegistryClient.shared.fetchManifest(forceRefresh: true)
        refreshRegistryUpdateSet()
        guard let manifest = RegistryClient.shared.manifest else {
            reconciliationManifestAttempts += 1
            guard reconciliationManifestAttempts < ReconciliationConfig.maxAttempts else {
                Self.logger.error("Reconciliation gave up: registry manifest unavailable")
                applyReason(registryUnreachableReason(), to: outdated)
                emitReconciliationOutcome()
                return
            }
            Self.logger.warning("Reconciliation deferred: registry manifest unavailable, will retry")
            scheduleReconciliationRetry()
            return
        }
        reconciliationManifestAttempts = 0

        var sawTransientFailure = false
        var retryRemaining = false
        for rejected in outdated {
            guard !Task.isCancelled else { return }
            if case .transient(let id) = await reconcile(rejected, manifest: manifest) {
                sawTransientFailure = true
                if reconciliationAttempts[id, default: 0] < ReconciliationConfig.maxAttempts {
                    retryRemaining = true
                }
            }
        }

        if Self.reconciliationShouldRetry(sawTransientFailure: sawTransientFailure, retryRemaining: retryRemaining) {
            scheduleReconciliationRetry()
            return
        }

        emitReconciliationOutcome()
    }

    static func reconciliationShouldRetry(sawTransientFailure: Bool, retryRemaining: Bool) -> Bool {
        sawTransientFailure && retryRemaining
    }

    private enum ReconcileOutcome {
        case resolved
        case permanent
        case missing
        case transient(id: String)
    }

    private func reconcile(_ rejected: RejectedPlugin, manifest: RegistryManifest) async -> ReconcileOutcome {
        guard let lookupId = resolveRegistryId(for: rejected, manifest: manifest),
              let registryPlugin = manifest.plugins.first(where: { $0.id == lookupId }) else {
            Self.logger.warning("Reconciliation: no registry entry for '\(rejected.name)'")
            updateRejectedReason(url: rejected.url, reason: missingFromRegistryReason())
            return .missing
        }

        let attempts = reconciliationAttempts[lookupId, default: 0]
        guard attempts < ReconciliationConfig.maxAttempts else { return .permanent }
        reconciliationAttempts[lookupId] = attempts + 1

        do {
            let outcome = try await updateFromRegistry(
                registryPlugin,
                existingPluginLoaded: false,
                refreshManifest: false,
                progress: { _ in }
            )
            switch outcome {
            case .installed:
                refreshRegistryUpdateSet()
                Self.logger.info("Reconciliation: auto-updated '\(rejected.name)'")
            case .staged:
                Self.logger.info("Reconciliation: staged '\(rejected.name)', will activate on disconnect")
            }
            removeFromRejected(url: rejected.url)
            reconciliationAttempts.removeValue(forKey: lookupId)
            return .resolved
        } catch let error as PluginError where error.isPermanentReconciliationFailure {
            reconciliationAttempts[lookupId] = ReconciliationConfig.maxAttempts
            updateRejectedReason(url: rejected.url, reason: incompatibleBuildReason(for: registryPlugin))
            Self.logger.error("Reconciliation: no compatible build for '\(rejected.name)'")
            return .permanent
        } catch {
            Self.logger.error("Reconciliation: transient failure for '\(rejected.name)': \(error.localizedDescription)")
            if reconciliationAttempts[lookupId, default: 0] >= ReconciliationConfig.maxAttempts {
                updateRejectedReason(url: rejected.url, reason: temporaryFailureReason())
            }
            return .transient(id: lookupId)
        }
    }

    private func scheduleReconciliationRetry() {
        let round = max(reconciliationAttempts.values.max() ?? 0, reconciliationManifestAttempts)
        let delay = round <= 1 ? ReconciliationConfig.firstRetryDelay : ReconciliationConfig.secondRetryDelay
        reconciliationTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.runReconciliationLoop()
        }
    }

    private func emitReconciliationOutcome() {
        AppEvents.shared.pluginsRejected.send(rejectedPlugins)
    }

    private func updateRejectedReason(url: URL, reason: String) {
        guard let index = rejectedPlugins.firstIndex(where: { $0.url == url }) else { return }
        let existing = rejectedPlugins[index]
        rejectedPlugins[index] = RejectedPlugin(
            url: existing.url,
            bundleId: existing.bundleId,
            registryId: existing.registryId,
            name: existing.name,
            reason: reason,
            isOutdated: existing.isOutdated
        )
    }

    private func incompatibleBuildReason(for registryPlugin: RegistryPlugin) -> String {
        let availableKits = registryPlugin.binaries
            .filter { $0.architecture == .current }
            .compactMap(\.pluginKitVersion)
        if availableKits.contains(where: { $0 > Self.currentPluginKitVersion }) {
            return String(localized: "A newer version of TablePro is required for this plugin. Update TablePro to keep using it.")
        }
        return String(localized: "No compatible build is available yet. This plugin will update automatically once one is published.")
    }

    private func missingFromRegistryReason() -> String {
        String(localized: "This plugin is not in the registry, so it can't be updated automatically.")
    }

    private func registryUnreachableReason() -> String {
        String(localized: "TablePro couldn't reach the plugin registry to update this plugin. Check your connection and reopen TablePro.")
    }

    private func temporaryFailureReason() -> String {
        String(localized: "Updating this plugin didn't finish. TablePro will try again the next time it launches.")
    }

    private func applyReason(_ reason: String, to plugins: [RejectedPlugin]) {
        for plugin in plugins {
            updateRejectedReason(url: plugin.url, reason: reason)
        }
    }

    func resolveRegistryId(for rejected: RejectedPlugin, manifest: RegistryManifest) -> String? {
        if let id = rejected.registryId { return id }
        if let bundleId = rejected.bundleId,
           manifest.plugins.contains(where: { $0.id == bundleId }) {
            return bundleId
        }
        return nil
    }

    func removeFromRejected(url: URL) {
        rejectedPlugins.removeAll { $0.url == url }
    }

    func registryUpdate(for pluginId: String) -> RegistryPlugin? {
        guard let manifest = RegistryClient.shared.manifest else { return nil }
        guard let installed = plugins.first(where: { $0.id == pluginId }) else { return nil }
        guard installed.source == .userInstalled else { return nil }
        guard let registryPlugin = manifest.plugins.first(where: { $0.id == pluginId }) else { return nil }
        guard registryPlugin.category != .theme else { return nil }
        return registryPlugin.version.compare(installed.version, options: .numeric) == .orderedDescending
            ? registryPlugin : nil
    }

    func refreshRegistryUpdateSet() {
        var available: Set<String> = []
        for plugin in plugins where registryUpdate(for: plugin.id) != nil {
            available.insert(plugin.id)
        }
        if available != pluginsWithRegistryUpdate {
            pluginsWithRegistryUpdate = available
        }
    }

    func registryPlugin(for rejected: RejectedPlugin) -> RegistryPlugin? {
        guard let manifest = RegistryClient.shared.manifest else { return nil }
        guard let id = resolveRegistryId(for: rejected, manifest: manifest) else { return nil }
        return manifest.plugins.first(where: { $0.id == id })
    }
}
