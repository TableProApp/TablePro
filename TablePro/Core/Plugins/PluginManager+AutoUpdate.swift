//
//  PluginManager+AutoUpdate.swift
//  TablePro
//

import Combine
import Foundation
import os

private enum ReconciliationConfig {
    static let maxAttempts = 5
    static let firstRetryDelay: Duration = .seconds(30)
    static let secondRetryDelay: Duration = .seconds(300)
    static let thirdRetryDelay: Duration = .seconds(600)
}

enum RejectedPluginAction: Sendable {
    case updateAvailable(RegistryPlugin)
    case awaitingCompatibleBuild
    case requiresAppUpdate
    case notInRegistry
}

extension PluginManager {
    func scheduleReconciliation() {
        reconciliationTask?.cancel()
        reconciliationActive = true
        reconciliationTask = Task { [weak self] in
            await self?.runReconciliationLoop()
        }
    }

    func runReconciliationLoop() async {
        defer { reconciliationActive = false }
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
            let action = Self.rejectedAction(
                registryPlugin: registryPlugin,
                manifestLoaded: true,
                currentKitVersion: Self.currentPluginKitVersion,
                minimumKitVersion: Self.minimumCompatiblePluginKitVersion
            )
            updateRejectedReason(url: rejected.url, reason: incompatibleBuildReason(for: registryPlugin))
            if case .noCompatibleBinary = error, case .awaitingCompatibleBuild = action {
                Self.logger.warning("Reconciliation: no compatible build published yet for '\(rejected.name)', will retry")
                return .transient(id: lookupId)
            }
            reconciliationAttempts[lookupId] = ReconciliationConfig.maxAttempts
            Self.logger.error("Reconciliation: '\(rejected.name)' needs a newer app or has no compatible build")
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
        let delay: Duration
        switch round {
        case ..<2: delay = ReconciliationConfig.firstRetryDelay
        case 2: delay = ReconciliationConfig.secondRetryDelay
        default: delay = ReconciliationConfig.thirdRetryDelay
        }
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
            isOutdated: existing.isOutdated,
            providedDatabaseTypeIds: existing.providedDatabaseTypeIds
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

    func rejectedAction(for rejected: RejectedPlugin) -> RejectedPluginAction {
        Self.rejectedAction(
            registryPlugin: registryPlugin(for: rejected),
            manifestLoaded: RegistryClient.shared.manifest != nil,
            currentKitVersion: Self.currentPluginKitVersion,
            minimumKitVersion: Self.minimumCompatiblePluginKitVersion
        )
    }

    static func rejectedAction(
        registryPlugin: RegistryPlugin?,
        manifestLoaded: Bool,
        currentKitVersion: Int,
        minimumKitVersion: Int
    ) -> RejectedPluginAction {
        guard manifestLoaded else { return .awaitingCompatibleBuild }
        guard let registryPlugin else { return .notInRegistry }
        let availableKits = registryPlugin.binaries
            .filter { $0.architecture == .current }
            .compactMap(\.pluginKitVersion)
        if availableKits.contains(where: { $0 >= minimumKitVersion && $0 <= currentKitVersion }) {
            return .updateAvailable(registryPlugin)
        }
        if availableKits.contains(where: { $0 > currentKitVersion }) {
            return .requiresAppUpdate
        }
        return .awaitingCompatibleBuild
    }

    func hasOutdatedRejectedPlugin(forTypeId typeId: String) -> Bool {
        rejectedPlugins.contains { $0.isOutdated && $0.providedDatabaseTypeIds.contains(typeId) }
    }

    func outdatedReconcileReason(forTypeId typeId: String) -> String? {
        rejectedPlugins.first { $0.isOutdated && $0.providedDatabaseTypeIds.contains(typeId) }?.reason
    }

    func prepareForConnecting(to type: DatabaseType) async {
        let typeId = type.pluginTypeId
        if driverPlugin(for: type) == nil, !hasFinishedInitialLoad {
            Self.logger.info("Plugin '\(typeId)' not loaded yet, waiting for background load")
            await waitForInitialLoad()
        }
        if driverPlugin(for: type) == nil, hasOutdatedRejectedPlugin(forTypeId: typeId) {
            Self.logger.info("Plugin '\(typeId)' is installed but outdated, updating it before connect")
            await ensurePluginReady(forTypeId: typeId)
        }
        if driverPlugin(for: type) == nil, type.isDownloadablePlugin, !hasOutdatedRejectedPlugin(forTypeId: typeId) {
            Self.logger.info("Plugin '\(typeId)' not installed, installing on demand before connect")
            do {
                try await installMissingPlugin(for: type) { _ in }
            } catch {
                Self.logger.warning("On-demand install for '\(typeId)' did not complete: \(error.localizedDescription)")
            }
        }
    }

    func ensurePluginReady(forTypeId typeId: String) async {
        if reconciliationActive, let task = reconciliationTask {
            await task.value
        }
        guard hasOutdatedRejectedPlugin(forTypeId: typeId) else { return }
        await reconcileOutdated(matchingTypeId: typeId)
    }

    private func reconcileOutdated(matchingTypeId typeId: String) async {
        let targets = rejectedPlugins.filter { $0.isOutdated && $0.providedDatabaseTypeIds.contains(typeId) }
        guard !targets.isEmpty else { return }
        reconciliationActive = true
        defer { reconciliationActive = false }
        await RegistryClient.shared.fetchManifest(forceRefresh: true)
        guard let manifest = RegistryClient.shared.manifest else { return }
        for target in targets {
            if let lookupId = resolveRegistryId(for: target, manifest: manifest) {
                reconciliationAttempts.removeValue(forKey: lookupId)
            }
            _ = await reconcile(target, manifest: manifest)
        }
        refreshRegistryUpdateSet()
        emitReconciliationOutcome()
    }

    func retriggerReconciliation() {
        guard !reconciliationActive else { return }
        guard rejectedPlugins.contains(where: \.isOutdated) else { return }
        reconciliationAttempts.removeAll()
        reconciliationManifestAttempts = 0
        scheduleReconciliation()
    }
}
