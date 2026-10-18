import Combine
import Foundation
import os

enum RejectedPluginAction: Sendable {
    case updateAvailable(RegistryPlugin)
    case awaitingCompatibleBuild
    case requiresAppUpdate
    case notInRegistry
}

struct RegistryUpdateTarget: Equatable, Sendable {
    let pluginId: String
    let build: Int
    let rejectedURL: URL?
}

struct PendingRegistryUpdate: Sendable {
    let target: RegistryUpdateTarget
    let plugin: RegistryPlugin
    let release: RegistryRelease
}

enum RegistryUpdatePassResult: Equatable, Sendable {
    case finished
    case retry
}

extension PluginManager {
    nonisolated static let registryUpdateMaxAttempts = 5

    nonisolated static func registryUpdateRetryDelay(afterAttempt attempt: Int) -> Duration? {
        switch attempt {
        case ..<1, registryUpdateMaxAttempts...: nil
        case 1: .seconds(30)
        case 2: .seconds(300)
        default: .seconds(600)
        }
    }

    func scheduleRegistryUpdatePass(after delay: Duration = .zero) {
        guard SoftwareUpdater.isUpdatingEnabled else { return }
        registryUpdateTask?.cancel()
        // A connection the initial load releases runs before this task starts, and must wait for its repairs.
        isRepairingRejectedPlugins = delay == .zero
        registryUpdateTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            await self?.performScheduledRegistryUpdatePass()
        }
    }

    private func performScheduledRegistryUpdatePass() async {
        let result = await runRegistryUpdatePass()
        guard !Task.isCancelled else { return }

        if result == .retry {
            registryUpdateAttempts += 1
            if let delay = Self.registryUpdateRetryDelay(afterAttempt: registryUpdateAttempts) {
                Self.logger.info("Plugin update pass will retry in \(delay.components.seconds) s")
                scheduleRegistryUpdatePass(after: delay)
                return
            }
            Self.logger.warning("Plugin update pass gave up after \(self.registryUpdateAttempts) attempts")
            markUnfinishedRejectedPlugins()
        }
        registryUpdateAttempts = 0
        AppEvents.shared.pluginsRejected.send(rejectedPlugins)
    }

    func runRegistryUpdatePass(
        registryClient: RegistryClient = .shared,
        appBuild: Int = Bundle.main.buildNumber
    ) async -> RegistryUpdatePassResult {
        isRepairingRejectedPlugins = true
        defer { isRepairingRejectedPlugins = false }
        return await applyRegistryUpdates(to: registryUpdateTargets(appBuild: appBuild), registryClient: registryClient)
    }

    func waitForRejectedPluginRepairs() async {
        guard isRepairingRejectedPlugins else { return }
        await withCheckedContinuation { rejectedRepairWaiters.append($0) }
    }

    private func applyRegistryUpdates(
        to targets: [RegistryUpdateTarget],
        registryClient: RegistryClient
    ) async -> RegistryUpdatePassResult {
        guard !targets.isEmpty else { return .finished }

        await registryClient.fetch(policy: .mustBeCurrent)
        guard registryClient.isManifestCurrent, let manifest = registryClient.manifest else {
            Self.logger.warning("Plugin update pass deferred: the plugin manifest is unavailable")
            return .retry
        }

        let pending = Self.pendingRegistryUpdates(
            installed: targets,
            manifest: manifest,
            channel: Self.registryChannel,
            kits: Self.compatibleKits,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersion
        )
        var result = RegistryUpdatePassResult.finished
        for update in pending {
            guard !Task.isCancelled else { return .finished }
            guard isRegistryUpdateTarget(update.target) else { continue }
            if update.target.rejectedURL == nil {
                isRepairingRejectedPlugins = false
            }
            do {
                try await applyRegistryUpdate(update)
            } catch {
                Self.logger.error("Updating '\(update.target.pluginId)' failed: \(error.localizedDescription)")
                result = .retry
            }
        }

        let updatedIds = Set(pending.map(\.target.pluginId))
        for target in targets where !updatedIds.contains(target.pluginId) {
            switch Self.rejectedAction(
                registryPlugin: manifest.plugins.first { $0.id == target.pluginId },
                manifestLoaded: true,
                kits: Self.compatibleKits
            ) {
            case .updateAvailable, .awaitingCompatibleBuild:
                result = .retry
            case .requiresAppUpdate:
                updateRejectedReason(url: target.rejectedURL, reason: requiresAppUpdateReason())
            case .notInRegistry:
                updateRejectedReason(url: target.rejectedURL, reason: missingFromRegistryReason())
            }
        }
        return result
    }

    // Rejected plugins come first: a connection waits on them, while a loaded plugin keeps working.
    func registryUpdateTargets(appBuild: Int) -> [RegistryUpdateTarget] {
        var targets: [RegistryUpdateTarget] = []
        for rejected in rejectedPlugins where rejected.isOutdated {
            guard let registryId = rejected.registryId ?? rejected.bundleId,
                  !targets.contains(where: { $0.pluginId == registryId }) else { continue }
            targets.append(RegistryUpdateTarget(pluginId: registryId, build: 0, rejectedURL: rejected.url))
        }
        for entry in plugins where entry.source == .userInstalled && entry.build < appBuild {
            guard !stagedPluginIds.contains(entry.id),
                  let registryId = Self.readRegistryMetadata(for: entry.url)?.pluginId,
                  !targets.contains(where: { $0.pluginId == registryId }) else { continue }
            targets.append(RegistryUpdateTarget(pluginId: registryId, build: entry.build, rejectedURL: nil))
        }
        return targets
    }

    // The pass suspends on the network, and the user may uninstall or remove a plugin meanwhile.
    func isRegistryUpdateTarget(_ target: RegistryUpdateTarget) -> Bool {
        if let rejectedURL = target.rejectedURL {
            return rejectedPlugins.contains { $0.url == rejectedURL }
        }
        guard !stagedPluginIds.contains(target.pluginId),
              let entry = plugins.first(where: { $0.id == target.pluginId }) else { return false }
        return entry.source == .userInstalled
            && entry.build == target.build
            && Self.readRegistryMetadata(for: entry.url)?.pluginId == target.pluginId
    }

    nonisolated static func pendingRegistryUpdates(
        installed: [RegistryUpdateTarget],
        manifest: RegistryManifest,
        channel: UpdateChannel,
        kits: ClosedRange<Int>,
        systemVersion: OperatingSystemVersion
    ) -> [PendingRegistryUpdate] {
        installed.compactMap { target in
            guard let plugin = manifest.plugins.first(where: { $0.id == target.pluginId }),
                  let release = try? plugin.newestRelease(channel: channel, kits: kits, systemVersion: systemVersion),
                  release.build > target.build else { return nil }
            return PendingRegistryUpdate(target: target, plugin: plugin, release: release)
        }
    }

    private func applyRegistryUpdate(_ update: PendingRegistryUpdate) async throws {
        switch try await updateFromRegistry(update.plugin, release: update.release, progress: { _ in }) {
        case .installed:
            Self.logger.info("Updated '\(update.target.pluginId)' to build \(update.release.build)")
        case .staged:
            Self.logger.info("Staged build \(update.release.build) of '\(update.target.pluginId)' for the next launch")
        }
    }

    private func markUnfinishedRejectedPlugins() {
        for rejected in rejectedPlugins where rejected.isOutdated {
            let reason: String
            switch rejectedAction(for: rejected) {
            case .requiresAppUpdate: reason = requiresAppUpdateReason()
            case .notInRegistry: reason = missingFromRegistryReason()
            case .awaitingCompatibleBuild where RegistryClient.shared.isManifestCurrent: reason = awaitingBuildReason()
            case .awaitingCompatibleBuild: reason = registryUnreachableReason()
            case .updateAvailable: reason = temporaryFailureReason()
            }
            updateRejectedReason(url: rejected.url, reason: reason)
        }
    }

    private func updateRejectedReason(url: URL?, reason: String) {
        guard let url, let index = rejectedPlugins.firstIndex(where: { $0.url == url }) else { return }
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

    private func requiresAppUpdateReason() -> String {
        String(localized: "A newer version of TablePro is required for this plugin. Update TablePro to keep using it.")
    }

    private func awaitingBuildReason() -> String {
        String(localized: "No compatible build is available yet. This plugin will update automatically once one is published.")
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

    // Only plist checks here: the signature was checked when staged and is checked again before any code loads.
    nonisolated static func applyStagedUpdates(in userPluginsDir: URL) {
        let fm = FileManager.default
        guard let stagedDirs = try? fm.contentsOfDirectory(
            at: PluginInstaller.stagedUpdatesRoot(for: userPluginsDir),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for stagedDir in stagedDirs {
            defer { try? fm.removeItem(at: stagedDir) }
            do {
                let bundleURL = try PluginInstaller.findBundle(in: stagedDir)
                guard let bundle = Bundle(url: bundleURL),
                      bundle.bundleIdentifier == stagedDir.lastPathComponent else {
                    throw PluginError.invalidBundle("The staged bundle is not \(stagedDir.lastPathComponent)")
                }
                try validateBundleVersions(bundle)
                let destURL = userPluginsDir.appendingPathComponent(bundleURL.lastPathComponent, isDirectory: true)
                _ = try PluginInstaller.atomicReplace(stagedBundleURL: bundleURL, destURL: destURL)
                logger.info("Applied the staged update of '\(stagedDir.lastPathComponent)'")
            } catch {
                logger.error("Dropped the staged update of '\(stagedDir.lastPathComponent)': \(error.localizedDescription)")
            }
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

    func registryPlugin(for rejected: RejectedPlugin) -> RegistryPlugin? {
        guard let manifest = RegistryClient.shared.manifest else { return nil }
        guard let id = resolveRegistryId(for: rejected, manifest: manifest) else { return nil }
        return manifest.plugins.first(where: { $0.id == id })
    }

    func rejectedAction(for rejected: RejectedPlugin) -> RejectedPluginAction {
        Self.rejectedAction(
            registryPlugin: registryPlugin(for: rejected),
            manifestLoaded: RegistryClient.shared.manifest != nil,
            kits: Self.compatibleKits
        )
    }

    static func rejectedAction(
        registryPlugin: RegistryPlugin?,
        manifestLoaded: Bool,
        kits: ClosedRange<Int>
    ) -> RejectedPluginAction {
        guard manifestLoaded else { return .awaitingCompatibleBuild }
        guard let registryPlugin else { return .notInRegistry }
        do {
            _ = try newestRelease(of: registryPlugin, kits: kits)
            return .updateAvailable(registryPlugin)
        } catch PluginError.appTooOldForPlugin {
            return .requiresAppUpdate
        } catch {
            return .awaitingCompatibleBuild
        }
    }

    func hasOutdatedRejectedPlugin(forTypeId typeId: String) -> Bool {
        rejectedPlugins.contains { $0.isOutdated && $0.providedDatabaseTypeIds.contains(typeId) }
    }

    func prepareForConnecting(to type: DatabaseType, registryClient: RegistryClient = .shared) async throws {
        let typeId = type.pluginTypeId
        if driverPlugin(for: type) == nil, !hasFinishedInitialLoad {
            Self.logger.info("Plugin '\(typeId)' not loaded yet, waiting for background load")
            await waitForInitialLoad()
        }
        if driverPlugin(for: type) == nil, hasOutdatedRejectedPlugin(forTypeId: typeId) {
            Self.logger.info("Plugin '\(typeId)' is installed but outdated, updating it before connect")
            await ensurePluginReady(forTypeId: typeId)
        }
        guard driverPlugin(for: type) == nil else { return }
        if PluginMetadataRegistry.shared.snapshot(for: type) == nil {
            await registryClient.fetch(policy: .ifStale)
        }
        let unavailability = driverUnavailability(for: type, registryManifest: registryClient.manifest)
        guard unavailability == .notInstalled else {
            Self.logger.info("Plugin '\(typeId, privacy: .public)' unavailable to connect: \(String(describing: unavailability), privacy: .public)")
            return
        }
        Self.logger.info("Plugin '\(typeId)' not installed, installing on demand before connect")
        do {
            try await installMissingPlugin(for: type, registryClient: registryClient) { _ in }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Self.logger.warning("On-demand install for '\(typeId)' did not complete: \(error.localizedDescription)")
            throw PluginError.pluginInstallFailed(
                databaseType: Self.registryDisplayName(of: type),
                reason: error.localizedDescription
            )
        }
    }

    func ensurePluginReady(forTypeId typeId: String) async {
        guard SoftwareUpdater.isUpdatingEnabled, hasOutdatedRejectedPlugin(forTypeId: typeId) else { return }
        await waitForRejectedPluginRepairs()
        let targets = registryUpdateTargets(forTypeId: typeId, appBuild: Bundle.main.buildNumber)
        guard !targets.isEmpty else { return }
        _ = await applyRegistryUpdates(to: targets, registryClient: .shared)
        AppEvents.shared.pluginsRejected.send(rejectedPlugins)
    }

    func registryUpdateTargets(forTypeId typeId: String, appBuild: Int) -> [RegistryUpdateTarget] {
        let rejectedURLs = Set(
            rejectedPlugins
                .filter { $0.isOutdated && $0.providedDatabaseTypeIds.contains(typeId) }
                .map(\.url)
        )
        return registryUpdateTargets(appBuild: appBuild).filter { target in
            target.rejectedURL.map { rejectedURLs.contains($0) } ?? false
        }
    }
}
