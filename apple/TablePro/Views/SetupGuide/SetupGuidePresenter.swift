//
//  SetupGuidePresenter.swift
//  TablePro
//

import AppKit

// Decides once per launch whether the guide opens, and holds the sign-in window back while it may.
@MainActor
internal final class SetupGuidePresenter {
    internal enum State: Equatable {
        case undecided
        case presenting
        case notShown
        case closed
    }

    internal struct Environment {
        var launchInputs: @MainActor (_ hasRoutedWork: Bool) -> SetupGuideGate.Inputs
        var present: @MainActor (SetupGuideGate.Trigger) -> Void
        var markSeen: @MainActor () -> Void
        var guideDidEnd: @MainActor () -> Void
    }

    internal static let shared = SetupGuidePresenter(environment: .live)

    internal private(set) var state: State = .undecided
    private let environment: Environment

    internal init(environment: Environment) {
        self.environment = environment
    }

    // The sign-in window waits while the guide is up, or could still open this launch.
    internal var isPending: Bool {
        switch state {
        case .presenting:
            true
        case .undecided:
            SetupGuideGate.shouldPresent(environment.launchInputs(false))
        case .notShown, .closed:
            false
        }
    }

    // Welcome's first frame; only the first of a launch decides.
    internal func welcomeDidAppear(hasRoutedWork: Bool) {
        guard state == .undecided else { return }
        guard SetupGuideGate.shouldPresent(environment.launchInputs(hasRoutedWork)) else {
            state = .notShown
            environment.guideDidEnd()
            return
        }
        state = .presenting
        environment.present(.launch)
    }

    internal func presentFromMenu() {
        state = .presenting
        environment.present(.menu)
    }

    // Every ending goes through here: Finish, Skip and closing the window.
    internal func guideDidClose() {
        environment.markSeen()
        state = .closed
        environment.guideDidEnd()
    }
}

internal extension SetupGuidePresenter.Environment {
    static var live: SetupGuidePresenter.Environment {
        SetupGuidePresenter.Environment(
            launchInputs: { hasRoutedWork in
                let library = ConnectionStorage.shared
                let readable = !library.isLibraryUnreadable
                // A launch intent leaves either a request with Welcome or the window it opened.
                let hasPrimaryWindow = NSApp.windows.contains { AppLaunchCoordinator.isMainWindow($0) && $0.isVisible }
                return SetupGuideGate.Inputs(
                    trigger: .launch,
                    isUserSession: AppActivationPolicyController.shared.origin == .user,
                    hasRoutedWork: hasRoutedWork || WelcomeRouter.shared.hasPendingWork || hasPrimaryWindow,
                    isUITestSandbox: AppStorageEnvironment.shared.isIsolated,
                    uiTestRequestsGuide: UITestLaunchEnvironment.requestsSetupGuide,
                    libraryReadable: readable,
                    connectionCount: library.loadConnections().count + library.unreadableConnectionIds.count,
                    hasSeen: AppSettingsStorage.shared.hasSeenSetupGuide()
                )
            },
            present: { SetupGuideWindowController.present(trigger: $0) },
            markSeen: { AppSettingsStorage.shared.markSetupGuideSeen() },
            guideDidEnd: { SignInPrompt.live.presentIfNeeded() }
        )
    }
}
