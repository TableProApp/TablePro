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
    private var installOnQuitNow: (() -> Void)?

    @Published private(set) var phase: AppUpdatePhase = .idle
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = true
    @Published private(set) var automaticallyDownloadsUpdates = true
    @Published private(set) var allowsAutomaticUpdates = true
    @Published private(set) var updateCheckInterval: TimeInterval = 0
    @Published private(set) var lastUpdateCheckDate: Date?
    @Published private(set) var channel: UpdateChannel = .stable

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

    // Brings a deferred update forward in Sparkle's own window, or starts a check when none is waiting.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    // Sparkle quits through the normal terminate path; a quit the user cancels leaves the handler usable again.
    func installAndRelaunch() -> Bool {
        guard let installOnQuitNow else { return false }
        installOnQuitNow()
        return true
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        updater.automaticallyChecksForUpdates = enabled
        refreshFromUpdater()
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        updater.automaticallyDownloadsUpdates = enabled
        refreshFromUpdater()
    }

    func setChannel(_ channel: UpdateChannel) {
        UpdateChannel.select(channel, in: defaults)
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

    fileprivate func apply(_ event: AppUpdateEvent) {
        let next = phase.applying(event)
        guard next != phase else { return }
        phase = next
    }

    fileprivate func recordReadyToInstallOnQuit(_ release: UpdateRelease, install: @escaping () -> Void) {
        installOnQuitNow = install
        apply(.readyToInstallOnQuit(release))
        Self.logger.info("Update \(release.version, privacy: .public) installs on quit")
    }

    fileprivate func recordUpdateCycleFinished(error: Error?) {
        refreshFromUpdater()
        guard let error else { return }
        let nsError = error as NSError
        guard nsError.code != Int(SUError.noUpdateError.rawValue) else { return }
        Self.logger.error("Update check failed: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)")
    }

    // Sparkle holds the driver behind the install block weakly, so after an abort the block does nothing.
    fileprivate func recordUpdateAborted(error: Error) {
        let nsError = error as NSError
        guard nsError.code != Int(SUError.noUpdateError.rawValue) else { return }
        installOnQuitNow = nil
        apply(.updateAborted)
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
        channel = UpdateChannel.selected(in: defaults)
    }
}

private extension UpdateRelease {
    init(_ item: SUAppcastItem) {
        self.init(version: item.displayVersionString, releaseNotesURL: item.fullReleaseNotesURL ?? item.releaseNotesURL)
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

    // The update Sparkle downloaded on its own; returning true keeps the handler for Relaunch to Update.
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        guard let owner else { return false }
        owner.recordReadyToInstallOnQuit(UpdateRelease(item), install: immediateInstallHandler)
        return true
    }
}

extension SoftwareUpdaterDelegate: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    // Sparkle asks for no side effects here; the reminder is recorded in the call that follows.
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate else { return }
        owner?.apply(.scheduledUpdateDeferred(UpdateRelease(update)))
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        owner?.apply(.updateReceivedAttention)
    }

    func standardUserDriverWillFinishUpdateSession() {
        owner?.apply(.updateSessionFinished)
    }
}
