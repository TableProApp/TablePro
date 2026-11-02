import AppKit
import os

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
    private let reviewUnsavedDocuments: @MainActor (@escaping @MainActor (Bool) -> Void) -> Void
    private let installPendingUpdate: @MainActor () -> Bool
    private let terminate: @MainActor () -> Void
    private let reopenAfterExit: @MainActor (_ pid: pid_t, _ bundleURL: URL) throws -> Void
    private var route: Route?

    init(
        defaults: UserDefaults = AppStorageEnvironment.shared.defaults,
        reviewUnsavedDocuments: @escaping @MainActor (@escaping @MainActor (Bool) -> Void) -> Void = UnsavedDocumentReview.run,
        installPendingUpdate: @escaping @MainActor () -> Bool = { SoftwareUpdater.shared.installAndRelaunch() },
        terminate: @escaping @MainActor () -> Void = { NSApp.terminate(nil) },
        reopenAfterExit: @escaping @MainActor (_ pid: pid_t, _ bundleURL: URL) throws -> Void = AppRelauncher.reopenAfterExit(pid:bundleURL:)
    ) {
        self.defaults = defaults
        self.reviewUnsavedDocuments = reviewUnsavedDocuments
        self.installPendingUpdate = installPendingUpdate
        self.terminate = terminate
        self.reopenAfterExit = reopenAfterExit
    }

    var isRelaunchPending: Bool { route != nil }

    // Documents are reviewed first: AppKit cancels a quit there before the app delegate hears of it.
    func relaunch() {
        reviewUnsavedDocuments { [weak self] proceed in
            guard let self, proceed else { return }
            self.route = .sparkleInstall
            guard !self.installPendingUpdate() else { return }
            self.route = .reopenAfterExit
            self.terminate()
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            #"while /bin/kill -0 "$0" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open "$1""#,
            String(pid),
            bundleURL.path,
        ]
        try process.run()
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
