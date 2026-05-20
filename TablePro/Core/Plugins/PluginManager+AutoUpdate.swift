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
            AppEvents.shared.pluginsRejected.send(rejectedPlugins)
            refreshRegistryUpdateSet()
            return
        }

        await RegistryClient.shared.fetchManifest()
        refreshRegistryUpdateSet()
        guard let manifest = RegistryClient.shared.manifest else {
            Self.logger.warning("Reconciliation skipped: registry manifest unavailable")
            AppEvents.shared.pluginsRejected.send(rejectedPlugins)
            return
        }

        for rejected in outdated {
            guard !Task.isCancelled else { return }

            guard let lookupId = resolveRegistryId(for: rejected, manifest: manifest),
                  let registryPlugin = manifest.plugins.first(where: { $0.id == lookupId }) else {
                Self.logger.warning("Reconciliation: no registry entry for '\(rejected.name)'")
                continue
            }

            let attempts = reconciliationAttempts[lookupId, default: 0]
            guard attempts < ReconciliationConfig.maxAttempts else {
                Self.logger.warning("Reconciliation: max attempts reached for '\(rejected.name)'")
                continue
            }

            reconciliationAttempts[lookupId] = attempts + 1

            do {
                let outcome = try await updateFromRegistry(
                    registryPlugin,
                    existingPluginLoaded: false,
                    progress: { _ in }
                )
                switch outcome {
                case .installed:
                    removeFromRejected(url: rejected.url)
                    reconciliationAttempts.removeValue(forKey: lookupId)
                    refreshRegistryUpdateSet()
                    Self.logger.info("Reconciliation: auto-updated '\(rejected.name)'")
                case .staged:
                    Self.logger.info("Reconciliation: staged update for '\(rejected.name)' (live connections)")
                }
            } catch {
                Self.logger.error("Reconciliation: update failed for '\(rejected.name)': \(error.localizedDescription)")
            }
        }

        AppEvents.shared.pluginsRejected.send(rejectedPlugins)
        scheduleReconciliationRetryIfNeeded(manifest: manifest)
    }

    private func scheduleReconciliationRetryIfNeeded(manifest: RegistryManifest) {
        let retryable = rejectedPlugins.filter(\.isOutdated).contains { rejected in
            guard let id = resolveRegistryId(for: rejected, manifest: manifest) else { return false }
            return reconciliationAttempts[id, default: 0] < ReconciliationConfig.maxAttempts
        }
        guard retryable else { return }

        let round = reconciliationAttempts.values.max() ?? 1
        let delay = round <= 1 ? ReconciliationConfig.firstRetryDelay : ReconciliationConfig.secondRetryDelay
        reconciliationTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.runReconciliationLoop()
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
