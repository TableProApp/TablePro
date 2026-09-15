//
//  UpdaterBridge.swift
//  TablePro
//
//  Observable mirror of SPUUpdater's own preferences for SwiftUI.
//

import Combine
import os
import Sparkle

/// Sparkle owns the update preferences, and this is the only place the app reads or writes them.
///
/// `SPUUpdater.h:192-209` says it twice: do not keep an additional user default for
/// `automaticallyChecksForUpdates`, and do not set it on every launch unless the user's own
/// preference is meant to be ignored. TablePro did both for its whole history, through a
/// `GeneralSettings` field written into Sparkle at launch and again whenever the settings pane
/// appeared. Because `GeneralSettings` syncs through iCloud as one blob, one Mac's choice also
/// overwrote another Mac's.
///
/// The values here are a mirror, not a store. Each is fed by KVO from the property that owns it,
/// so an external write (a managed preference, Sparkle's own permission prompt) shows up without
/// anything having to notice it happened.
@MainActor
final class UpdaterBridge: ObservableObject, UpdaterSettingsWriting {
    static let shared = UpdaterBridge()

    private static let logger = Logger(subsystem: "com.TablePro", category: "UpdaterBridge")

    /// The keys Sparkle itself observes, listed in `SPUUpdaterSettings.m`. Removing them is what
    /// hands governance back to Info.plist, which is what resetting settings has to mean.
    private static let sparkleDefaultsKeys = [
        "SUEnableAutomaticChecks",
        "SUScheduledCheckInterval",
        "SUAutomaticallyUpdate",
    ]

    private let controller: SPUStandardUpdaterController
    private var observations: [NSKeyValueObservation] = []

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = true
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var allowsAutomaticUpdates = true
    @Published private(set) var updateCheckInterval: TimeInterval = UpdateCheckFrequency.daily.seconds

    deinit {
        observations.forEach { $0.invalidate() }
    }

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: Self.startsUpdater,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        observeUpdater()
        refreshFromUpdater()
    }

    /// Sparkle keeps its state in the real `com.TablePro` domain, which a UI test's storage sandbox
    /// cannot redirect. Started there, it asks the runner for permission on the second launch, and
    /// that prompt takes the key window from every test after it.
    private static var startsUpdater: Bool {
        !AppStorageEnvironment.shared.isIsolated
    }

    var updater: SPUUpdater {
        controller.updater
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        updater.automaticallyChecksForUpdates = enabled
        refreshFromUpdater()
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        updater.automaticallyDownloadsUpdates = enabled
        refreshFromUpdater()
    }

    func setUpdateCheckInterval(_ interval: TimeInterval) {
        updater.updateCheckInterval = interval
        refreshFromUpdater()
    }

    /// Hands the update preferences back to Info.plist.
    ///
    /// `AppSettingsManager.resetToDefaults()` reassigns the settings structs, and these three
    /// values are not in them. Without this, "reset all settings across every section" would
    /// leave the update section exactly as the user set it.
    func resetUpdatePreferences() {
        let defaults = UserDefaults.standard
        for key in Self.sparkleDefaultsKeys {
            defaults.removeObject(forKey: key)
        }
        refreshFromUpdater()
        Self.logger.info("Update preferences reset to the values declared in Info.plist")
    }

    private func observeUpdater() {
        let updater = controller.updater
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshFromUpdater() }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshFromUpdater() }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshFromUpdater() }
            },
            updater.observe(\.updateCheckInterval, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshFromUpdater() }
            },
        ]
    }

    /// Called after every write and from every observation, so a missed KVO edge cannot leave a
    /// control showing something the updater does not agree with.
    private func refreshFromUpdater() {
        let updater = controller.updater
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        allowsAutomaticUpdates = updater.allowsAutomaticUpdates
        updateCheckInterval = updater.updateCheckInterval
    }
}
