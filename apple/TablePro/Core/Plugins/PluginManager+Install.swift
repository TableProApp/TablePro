import Foundation
import os

enum RegistryUpdateMode: Equatable, Sendable {
    case installNow
    case stageForNextLaunch
}

extension PluginManager {
    func installFromRegistry(
        _ registryPlugin: RegistryPlugin,
        release: RegistryRelease? = nil,
        trigger: PluginInstallTracker.Trigger
    ) async throws -> PluginEntry {
        if plugins.contains(where: { $0.id == registryPlugin.id }) {
            throw PluginError.pluginConflict(existingName: registryPlugin.name)
        }
        try reserveInstall(of: registryPlugin.id)
        defer { installsInFlight.remove(registryPlugin.id) }

        return try await installTracker.track(
            pluginId: registryPlugin.id,
            displayName: registryPlugin.name,
            trigger: trigger,
            retry: .registry(registryPlugin)
        ) { [self] ticket in
            let release = try release ?? Self.newestRelease(of: registryPlugin)
            let finalURL = try await registryInstaller.install(
                registryPlugin,
                release: release,
                into: userPluginsDir,
                progress: ticket.reportProgress
            )
            ticket.markInstalling()
            saveRegistryMetadata(pluginId: registryPlugin.id, pluginURL: finalURL)
            return try await loadPluginAsync(at: finalURL, source: .userInstalled)
        }
    }

    // A loaded bundle cannot be unloaded and Bundle(url:) caches per path, so it updates at the next launch.
    func registryUpdateMode(forPluginId pluginId: String) -> RegistryUpdateMode {
        plugins.contains { $0.id == pluginId } ? .stageForNextLaunch : .installNow
    }

    func updateFromRegistry(
        _ registryPlugin: RegistryPlugin,
        release: RegistryRelease? = nil,
        trigger: PluginInstallTracker.Trigger
    ) async throws -> PluginUpdateOutcome {
        switch registryUpdateMode(forPluginId: registryPlugin.id) {
        case .installNow:
            let entry = try await installFromRegistry(registryPlugin, release: release, trigger: trigger)
            rejectedPlugins.removeAll { ($0.registryId ?? $0.bundleId) == registryPlugin.id }
            return .installed(entry)
        case .stageForNextLaunch:
            try await stageFromRegistry(registryPlugin, release: release, trigger: trigger)
            return .staged(pluginId: registryPlugin.id)
        }
    }

    private func stageFromRegistry(
        _ registryPlugin: RegistryPlugin,
        release: RegistryRelease?,
        trigger: PluginInstallTracker.Trigger
    ) async throws {
        guard let existing = plugins.first(where: { $0.id == registryPlugin.id }) else {
            throw PluginError.notFound
        }
        guard existing.source == .userInstalled else {
            throw PluginError.pluginConflict(existingName: existing.name)
        }
        try reserveInstall(of: existing.id)
        defer { installsInFlight.remove(existing.id) }

        try await installTracker.track(
            pluginId: existing.id,
            displayName: existing.name,
            trigger: trigger,
            retry: .registry(registryPlugin)
        ) { [self] ticket in
            let release = try release ?? Self.newestRelease(of: registryPlugin)
            let stagedURL = try await registryInstaller.stage(
                registryPlugin,
                release: release,
                pluginId: existing.id,
                bundleName: existing.url.lastPathComponent,
                into: userPluginsDir,
                progress: ticket.reportProgress
            )
            ticket.markInstalling()
            // The next launch installs whatever build the staged bundle holds, whatever the manifest said.
            guard Self.bundleBuild(at: stagedURL) > existing.build else {
                removeStagedUpdate(pluginId: existing.id)
                throw PluginError.installFailed(String(localized: "The downloaded plugin is not newer than the installed one."))
            }
            guard plugins.contains(where: { $0.id == existing.id }) else {
                removeStagedUpdate(pluginId: existing.id)
                throw PluginError.notFound
            }
            stagedPluginIds.insert(existing.id)
        }
    }

    // One install per plugin at a time: a file and a registry download would overwrite each other's copy.
    private func reserveInstall(of pluginId: String) throws {
        guard !installsInFlight.contains(pluginId) else {
            throw PluginError.installFailed(
                String(localized: "Another install is already in progress for this plugin")
            )
        }
        installsInFlight.insert(pluginId)
    }

    func installPlugin(from url: URL) async throws -> PluginEntry {
        try await installTracker.track(
            pluginId: Self.fileInstallKey(for: url),
            displayName: url.deletingPathExtension().lastPathComponent,
            trigger: .user,
            retry: .file(url),
            startPhase: .installing
        ) { [self] _ in
            if url.pathExtension == "tableplugin" {
                return try await installLooseBundle(from: url)
            }
            return try await installLocalZip(from: url)
        }
    }

    // The bundle id is unknown until the file is read, so the file stands in for it.
    nonisolated static func fileInstallKey(for url: URL) -> String {
        "file:" + url.standardizedFileURL.path
    }

    func removeStagedUpdate(pluginId: String) {
        let stagedDir = PluginInstaller.stagedUpdateDirectory(for: pluginId, in: userPluginsDir)
        do {
            try FileManager.default.removeItem(at: stagedDir)
        } catch CocoaError.fileNoSuchFile {
            // Nothing was staged.
        } catch {
            Self.logger.error("Failed to remove the staged update of '\(pluginId)': \(error.localizedDescription)")
        }
        stagedPluginIds.remove(pluginId)
    }

    nonisolated static func newestRelease(
        of registryPlugin: RegistryPlugin,
        kits: ClosedRange<Int> = compatibleKits
    ) throws -> RegistryRelease {
        try registryPlugin.newestRelease(
            channel: registryChannel,
            kits: kits,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersion
        )
    }

    // MARK: - Local bundle / zip install

    // A file never puts back an older build than the one installed or staged. It drops the registry sidecar only at
    // or above the app's build, which the update pass never targets; below it the pass keeps the plugin current.
    nonisolated static func refuseOlderFile(build: Int, installedBuild: Int?) throws {
        guard let installedBuild, build < installedBuild else { return }
        throw PluginError.installFailed(String(
            format: String(localized: """
                The file holds build %1$ld of this plugin, older than build %2$ld on this Mac. To install an older \
                build, uninstall or remove the installed plugin first, then open the file.
                """),
            build,
            installedBuild
        ))
    }

    func installedBuild(of existing: PluginEntry) -> Int {
        let staged = PluginInstaller.stagedUpdateDirectory(for: existing.id, in: userPluginsDir)
            .appendingPathComponent(existing.url.lastPathComponent, isDirectory: true)
        return max(existing.build, Self.bundleBuild(at: staged))
    }

    func rejectedBuild(of bundleId: String) -> Int? {
        rejectedPlugins
            .filter { $0.bundleId == bundleId || $0.registryId == bundleId }
            .map { Self.bundleBuild(at: $0.url) }
            .max()
    }

    private func installLooseBundle(from url: URL) async throws -> PluginEntry {
        guard let sourceBundle = Bundle(url: url) else {
            throw PluginError.invalidBundle("Cannot create bundle from \(url.lastPathComponent)")
        }
        try PluginCodeSignatureVerifier.verify(bundle: sourceBundle)
        try Self.validateBundleVersions(sourceBundle)
        let bundleId = sourceBundle.bundleIdentifier ?? url.lastPathComponent
        try reserveInstall(of: bundleId)
        defer { installsInFlight.remove(bundleId) }

        if let existing = plugins.first(where: { $0.id == bundleId }) {
            guard url.standardizedFileURL != existing.url.standardizedFileURL else { return existing }
            try Self.refuseOlderFile(build: Self.bundleBuild(at: url), installedBuild: installedBuild(of: existing))
            PluginInstaller.stripQuarantine(at: url)
            return try stageForNextLaunch(bundleAt: url, replacing: existing)
        }
        let fileBuild = Self.bundleBuild(at: url)
        let rejected = rejectedBuild(of: bundleId)
        try Self.refuseOlderFile(build: fileBuild, installedBuild: rejected)

        try FileManager.default.createDirectory(at: userPluginsDir, withIntermediateDirectories: true)
        let destURL = userPluginsDir.appendingPathComponent(url.lastPathComponent)
        let loadURL: URL
        if url.standardizedFileURL != destURL.standardizedFileURL {
            loadURL = try PluginInstaller.atomicReplace(stagedBundleURL: url, destURL: destURL)
        } else {
            loadURL = destURL
        }
        PluginInstaller.stripQuarantine(at: loadURL)
        if rejected == nil || fileBuild >= Bundle.main.buildNumber {
            removeRegistryMetadata(for: loadURL)
        }
        return try await loadPluginAsync(at: loadURL, source: .userInstalled)
    }

    private func installLocalZip(from url: URL) async throws -> PluginEntry {
        let stagingRoot = PluginInstaller.stagingRoot(for: userPluginsDir)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let workingDir = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workingDir) }

        try PluginInstaller.extractZip(at: url, into: workingDir)
        let bundleURL = try PluginInstaller.findBundle(in: workingDir)
        guard let bundle = Bundle(url: bundleURL) else {
            throw PluginError.invalidBundle("Cannot create bundle from \(bundleURL.lastPathComponent)")
        }
        try PluginCodeSignatureVerifier.verify(bundle: bundle)
        try Self.validateBundleVersions(bundle)
        PluginInstaller.stripQuarantine(at: bundleURL)

        let bundleId = bundle.bundleIdentifier ?? bundleURL.lastPathComponent
        try reserveInstall(of: bundleId)
        defer { installsInFlight.remove(bundleId) }

        if let existing = plugins.first(where: { $0.id == bundleId }) {
            return try stageForNextLaunch(bundleAt: bundleURL, replacing: existing)
        }
        let fileBuild = Self.bundleBuild(at: bundleURL)
        let rejected = rejectedBuild(of: bundleId)
        try Self.refuseOlderFile(build: fileBuild, installedBuild: rejected)

        try FileManager.default.createDirectory(at: userPluginsDir, withIntermediateDirectories: true)
        let destURL = userPluginsDir.appendingPathComponent(bundleURL.lastPathComponent)
        let finalURL = try PluginInstaller.atomicReplace(stagedBundleURL: bundleURL, destURL: destURL)
        if rejected == nil || fileBuild >= Bundle.main.buildNumber {
            removeRegistryMetadata(for: finalURL)
        }
        return try await loadPluginAsync(at: finalURL, source: .userInstalled)
    }

    func stageForNextLaunch(
        bundleAt bundleURL: URL,
        replacing existing: PluginEntry,
        appBuild: Int = Bundle.main.buildNumber
    ) throws -> PluginEntry {
        let fileBuild = Self.bundleBuild(at: bundleURL)
        try Self.refuseOlderFile(build: fileBuild, installedBuild: installedBuild(of: existing))
        try PluginInstaller.stage(
            bundleAt: bundleURL,
            pluginId: existing.id,
            bundleName: existing.url.lastPathComponent,
            userPluginsDir: userPluginsDir
        )
        if fileBuild >= appBuild {
            removeRegistryMetadata(for: existing.url)
        }
        stagedPluginIds.insert(existing.id)
        return existing
    }
}

enum PluginUpdateOutcome: Sendable {
    case installed(PluginEntry)
    case staged(pluginId: String)
}
