import AppKit
import os
import TableProProcess

// AppKit has no relaunch call. A second instance started before the quit is approved keeps running
// when the user cancels it, and runs from a bundle Sparkle is about to replace, so the reopen waits
// for this process to exit.
@MainActor
final class AppRelauncher {
    static let shared = AppRelauncher()

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "AppRelauncher")

    private enum Route {
        case sparkleInstall
        case reopenAfterExit
    }

    private let defaults: UserDefaults
    private let approveStoppingWork: @MainActor () -> QuitPlan?
    private let commitBeforeQuitting: @MainActor (QuitPlan) async -> Bool
    private let reviewUnsavedDocuments: @MainActor (@escaping @MainActor (Bool) -> Void) -> Void
    private let installPendingUpdate: @MainActor () -> Bool
    private let terminate: @MainActor () -> Void
    private let performOutsideTask: @MainActor (@escaping @MainActor () -> Void) -> Void
    private let reopenAfterExit: @MainActor (_ pid: pid_t, _ bundleURL: URL) throws -> Void
    private var route: Route?
    private(set) var pendingCommit: Task<Void, Never>?

    init(
        defaults: UserDefaults = AppStorageEnvironment.shared.defaults,
        approveStoppingWork: @escaping @MainActor () -> QuitPlan? = {
            // Everything that can still refuse asks here, before Sparkle or the quit takes over.
            guard ThemeEditorWindows.shared.prepareToTerminate() else { return nil }
            return QuitApproval.approvesStoppingWork(registry: .shared, action: .relaunch)
        },
        commitBeforeQuitting: @escaping @MainActor (QuitPlan) async -> Bool = { await QuitApproval.commitBeforeQuitting($0) },
        reviewUnsavedDocuments: @escaping @MainActor (@escaping @MainActor (Bool) -> Void) -> Void = UnsavedDocumentReview.run,
        installPendingUpdate: @escaping @MainActor () -> Bool = { SoftwareUpdater.shared.installAndRelaunch() },
        terminate: @escaping @MainActor () -> Void = { NSApp.terminate(nil) },
        performOutsideTask: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void = AppRelauncher.performOnNextRunLoopTurn,
        reopenAfterExit: @escaping @MainActor (_ pid: pid_t, _ bundleURL: URL) throws -> Void = AppRelauncher.reopenAfterExit(pid:bundleURL:)
    ) {
        self.defaults = defaults
        self.approveStoppingWork = approveStoppingWork
        self.commitBeforeQuitting = commitBeforeQuitting
        self.reviewUnsavedDocuments = reviewUnsavedDocuments
        self.installPendingUpdate = installPendingUpdate
        self.terminate = terminate
        self.performOutsideTask = performOutsideTask
        self.reopenAfterExit = reopenAfterExit
    }

    var isRelaunchPending: Bool { route != nil }

    // The relaunch asked about running work itself, so the quit it starts does not ask again.
    var hasApprovedRunningWork: Bool { route != nil }

    // Documents are reviewed first: AppKit cancels a quit there before the app delegate hears of it.
    func relaunch() {
        // A commit still running is this same relaunch.
        guard pendingCommit == nil else { return }
        reviewUnsavedDocuments { [weak self] proceed in
            guard let self, proceed, let plan = self.approveStoppingWork() else { return }
            guard !plan.commits.isEmpty else {
                self.quitToRelaunch()
                return
            }
            // The commit runs before Sparkle or the quit takes over, since the quit it starts asks nothing.
            self.pendingCommit = Task { [weak self] in
                guard let self else { return }
                let committed = await self.commitBeforeQuitting(plan)
                self.pendingCommit = nil
                guard committed else { return }
                // A terminate from inside a main-actor job never lets the quit's reply task run.
                self.performOutsideTask { [weak self] in self?.quitToRelaunch() }
            }
        }
    }

    private func quitToRelaunch() {
        route = .sparkleInstall
        guard !installPendingUpdate() else { return }
        route = .reopenAfterExit
        terminate()
    }

    static func performOnNextRunLoopTurn(_ body: @escaping @MainActor () -> Void) {
        RunLoop.main.perform {
            MainActor.assumeIsolated(body)
        }
    }

    func terminationWasCancelled() {
        route = nil
    }

    // The quit is committed here, so this is the only place the next launch is told to reopen.
    func applicationWillTerminate(
        processIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier,
        bundleURL: URL = Bundle.main.bundleURL
    ) {
        guard let route else { return }
        self.route = nil
        if route == .reopenAfterExit {
            do {
                try reopenAfterExit(processIdentifier, bundleURL)
            } catch {
                Self.logger.error("Could not schedule the relaunch: \(error.publicLogShape, privacy: .public)")
                return
            }
        }
        defaults.set(true, forKey: PreferenceKeys.reopenSessionAfterRelaunch.name)
    }

    // Read once at launch, whatever the launch turns out to be, so a stale request never reopens a later one.
    static func consumeReopenRequest(in defaults: UserDefaults = AppStorageEnvironment.shared.defaults) -> Bool {
        let key = PreferenceKeys.reopenSessionAfterRelaunch.name
        guard defaults.bool(forKey: key) else { return false }
        defaults.removeObject(forKey: key)
        return true
    }

    nonisolated static func reopenAfterExit(pid: pid_t, bundleURL: URL) throws {
        try ProcessLauncher.process(for: .reopen(bundleURL, afterExitOf: pid)).run()
    }
}

@MainActor
final class UnsavedDocumentReview: NSObject {
    private static var active: UnsavedDocumentReview?
    private let completion: @MainActor (Bool) -> Void

    private init(completion: @escaping @MainActor (Bool) -> Void) {
        self.completion = completion
    }

    static func run(_ completion: @escaping @MainActor (Bool) -> Void) {
        let controller = NSDocumentController.shared
        guard controller.hasEditedDocuments else {
            completion(true)
            return
        }
        let review = UnsavedDocumentReview(completion: completion)
        active = review
        controller.reviewUnsavedDocuments(
            withAlertTitle: nil,
            cancellable: true,
            delegate: review,
            didReviewAllSelector: #selector(documentController(_:didReviewAll:contextInfo:)),
            contextInfo: nil
        )
    }

    @objc private func documentController(
        _ controller: NSDocumentController,
        didReviewAll: Bool,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        Self.active = nil
        completion(didReviewAll)
    }
}
