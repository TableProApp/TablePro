//
//  SoftwareUpdater.swift
//  TablePro
//

import Foundation
import Observation
import os
import Sparkle

/// Sparkle owns the update preferences, and this is the only place the app reads or writes them.
///
/// `SPUUpdater.h:198-201` says it twice: do not keep an additional user default for
/// `automaticallyChecksForUpdates`, and do not set it on every launch unless the user's own
/// preference is meant to be ignored. The initial values belong in Info.plist instead, which is
/// what `SparkleUpdatePreferences` pins.
///
/// The published values are a mirror, not a store. Each is fed by KVO from the property that owns
/// it, so a managed preference or Sparkle's own alert reaches the UI without anything having to
/// notice it happened.
@Observable
@MainActor
final class SoftwareUpdater {
    static let shared = SoftwareUpdater()

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "SoftwareUpdater")

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    /// Retained here because `SPUStandardUpdaterController` holds both delegates weakly.
    @ObservationIgnored private let delegate = SoftwareUpdaterDelegate()
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var hasStarted = false

    private(set) var canCheckForUpdates = false
    private(set) var automaticallyChecksForUpdates = true
    private(set) var automaticallyDownloadsUpdates = true
    private(set) var allowsAutomaticUpdates = true
    private(set) var updateCheckInterval: TimeInterval = 0
    private(set) var lastUpdateCheckDate: Date?

    /// A scheduled update the app declined to put in front of the user. Both the app menu item and
    /// the settings button read it, because a gentle reminder that shows in one place a person
    /// never opens is the same as no reminder at all.
    private(set) var hasPendingUpdate = false

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: delegate,
            userDriverDelegate: delegate
        )
        delegate.owner = self
        observeUpdater()
        refreshFromUpdater()
    }

    /// Started from `AppDelegate.runPostLaunchActivationIfNeeded()`, beside every other deferred
    /// service, rather than by whichever view reads `shared` first.
    ///
    /// Left implicit, the update cycle began as a side effect of building a view. The only
    /// launch-adjacent reader was the usage heartbeat, which returns before it builds a payload
    /// when analytics are off, and a person who also reopens their last session builds no welcome
    /// window either: Sparkle then never started, and no scheduled check ever ran.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        controller.startUpdater()
        refreshFromUpdater()
    }

    var updater: SPUUpdater {
        controller.updater
    }

    /// The title both the app menu item and the settings button show, so a deferred update is
    /// announced in the two places a person looks without either inventing its own wording.
    var checkForUpdatesTitle: String {
        Self.checkForUpdatesTitle(hasPendingUpdate: hasPendingUpdate)
    }

    /// Split out so the wording can be pinned by a test without a live updater, which building the
    /// singleton in a unit-test process would mean.
    static func checkForUpdatesTitle(hasPendingUpdate: Bool) -> String {
        hasPendingUpdate
            ? String(localized: "Update Available…")
            : String(localized: "Check for Updates…")
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

    /// Hands the update preferences back to Info.plist.
    ///
    /// `AppSettingsManager.resetToDefaults()` reassigns the settings structs, and these values are
    /// not in them, so without this "reset all settings across every section" would leave the
    /// update section exactly as the user set it.
    ///
    /// The standard domain rather than `AppStorageEnvironment`: Sparkle reaches these keys through
    /// `SUHost`, which reads the main bundle's own domain, so a redirected suite would clear a
    /// copy nothing consults.
    func resetUpdatePreferences() {
        SparkleUpdatePreferences.reset(in: UserDefaults.standard)
        refreshFromUpdater()
        Self.logger.info("Update preferences reset to the values declared in Info.plist")
    }

    fileprivate func recordDeferredUpdate() {
        hasPendingUpdate = true
    }

    fileprivate func clearDeferredUpdate() {
        hasPendingUpdate = false
    }

    fileprivate func recordUpdateCycleFinished(error: Error?) {
        refreshFromUpdater()
        guard let error else { return }
        let nsError = error as NSError
        guard nsError.code != Int(SUError.noUpdateError.rawValue) else { return }
        Self.logger.error("Update check failed: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)")
    }

    fileprivate func recordUpdateAborted(error: Error) {
        let nsError = error as NSError
        guard nsError.code != Int(SUError.noUpdateError.rawValue) else { return }
        Self.logger.error("Update driver aborted: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)")
    }

    /// Every property here is documented KVO-compliant in `SPUUpdater.h`.
    ///
    /// The hop onto the main actor is not ceremony and must stay. `SPUUpdater` is
    /// `NS_SWIFT_UI_ACTOR`, but these notifications do not all originate in the app: `SUHost.m:88`
    /// puts a KVO observer on `NSUserDefaults`, and a change written from outside the process, which
    /// is exactly what a managed preference is, arrives on whatever thread delivers it. Reading the
    /// updater there would be off-actor, and `assumeIsolated` would trap rather than lag.
    private func observeUpdater() {
        let updater = controller.updater
        func mirror<Value>(_ keyPath: KeyPath<SPUUpdater, Value>) -> NSKeyValueObservation {
            updater.observe(keyPath, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshFromUpdater() }
            }
        }
        observations = [
            mirror(\.canCheckForUpdates),
            mirror(\.automaticallyChecksForUpdates),
            mirror(\.automaticallyDownloadsUpdates),
            mirror(\.allowsAutomaticUpdates),
            mirror(\.updateCheckInterval),
        ]
    }

    /// Called after every write and from every observation, so a missed KVO edge cannot leave a
    /// control showing something the updater does not agree with. `lastUpdateCheckDate` is not
    /// documented KVO-compliant, so it rides along here and on the update-cycle callback instead.
    private func refreshFromUpdater() {
        let updater = controller.updater
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        allowsAutomaticUpdates = updater.allowsAutomaticUpdates
        updateCheckInterval = updater.updateCheckInterval
        lastUpdateCheckDate = updater.lastUpdateCheckDate
    }
}

/// Sparkle's two delegate surfaces, kept off `SoftwareUpdater` so the app's model is not also an
/// `NSObject` bound to an Objective-C protocol.
@MainActor
private final class SoftwareUpdaterDelegate: NSObject {
    weak var owner: SoftwareUpdater?
}

extension SoftwareUpdaterDelegate: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        owner?.recordUpdateCycleFinished(error: error)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        owner?.recordUpdateAborted(error: error)
    }
}

/// Gentle scheduled reminders, the shape Sparkle documents for an app with a Dock icon: a check the
/// person did not ask for never takes the front, and the app carries the news in its own UI until
/// they come back to it.
extension SoftwareUpdaterDelegate: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        guard immediateFocus else {
            owner?.recordDeferredUpdate()
            return false
        }
        return true
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        owner?.clearDeferredUpdate()
    }

    func standardUserDriverWillFinishUpdateSession() {
        owner?.clearDeferredUpdate()
    }
}
