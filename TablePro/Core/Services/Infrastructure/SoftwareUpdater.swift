import Combine
import Foundation
import os
import Sparkle

@MainActor
final class SoftwareUpdater: ObservableObject {
    static let shared = SoftwareUpdater()

    // A Debug build shares the installed app's defaults and plugin folder, and Sparkle would replace it with a release.
    #if DEBUG
    nonisolated static let isUpdatingEnabled = false
    #else
    nonisolated static let isUpdatingEnabled = true
    #endif

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "SoftwareUpdater")

    private let controller: SPUStandardUpdaterController
    // Retained here because `SPUStandardUpdaterController` holds both delegates weakly.
    private let delegate = SoftwareUpdaterDelegate()
    private let defaults = AppStorageEnvironment.shared.defaults
    private var observations: [NSKeyValueObservation] = []
    private var hasStarted = false

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = true
    @Published private(set) var automaticallyDownloadsUpdates = true
    @Published private(set) var allowsAutomaticUpdates = true
    @Published private(set) var updateCheckInterval: TimeInterval = 0
    @Published private(set) var lastUpdateCheckDate: Date?
    @Published private(set) var receivesBetaUpdates = false
    @Published private(set) var hasPendingUpdate = false

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

    // Started by AppDelegate at launch: a restored session with analytics off builds nothing that reads `shared`.
    func start() {
        guard Self.isUpdatingEnabled, !hasStarted else { return }
        hasStarted = true
        controller.startUpdater()
        refreshFromUpdater()
    }

    var updater: SPUUpdater {
        controller.updater
    }

    var checkForUpdatesTitle: String {
        Self.checkForUpdatesTitle(hasPendingUpdate: hasPendingUpdate)
    }

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

    func setReceivesBetaUpdates(_ enabled: Bool) {
        UpdateChannel.select(enabled ? .beta : .stable, in: defaults)
        if hasStarted {
            updater.resetUpdateCycleAfterShortDelay()
        }
        refreshFromUpdater()
    }

    func resetUpdatePreferences() {
        // Sparkle reads these through `SUHost`, which uses the main bundle's own domain, never a redirected suite.
        SparkleUpdatePreferences.reset(in: UserDefaults.standard)
        UpdateChannel.clearSelection(in: defaults)
        refreshFromUpdater()
        Self.logger.info("Update preferences reset to the values declared in Info.plist")
    }

    fileprivate var allowedChannels: Set<String> {
        UpdateChannel.selected(in: defaults).sparkleChannels
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

    private func observeUpdater() {
        let updater = controller.updater
        func mirror<Value>(_ keyPath: KeyPath<SPUUpdater, Value>) -> NSKeyValueObservation {
            updater.observe(keyPath, options: [.new]) { [weak self] _, _ in
                // A managed preference reaches `SUHost`'s defaults observer off the main thread.
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

    private func refreshFromUpdater() {
        let updater = controller.updater
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        allowsAutomaticUpdates = updater.allowsAutomaticUpdates
        updateCheckInterval = updater.updateCheckInterval
        // Not KVO-compliant, so it is read here and on the update-cycle callback.
        lastUpdateCheckDate = updater.lastUpdateCheckDate
        receivesBetaUpdates = UpdateChannel.selected(in: defaults) == .beta
    }
}

@MainActor
private final class SoftwareUpdaterDelegate: NSObject {
    weak var owner: SoftwareUpdater?
}

extension SoftwareUpdaterDelegate: SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        owner?.allowedChannels ?? []
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        owner?.recordUpdateCycleFinished(error: error)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        owner?.recordUpdateAborted(error: error)
    }
}

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
