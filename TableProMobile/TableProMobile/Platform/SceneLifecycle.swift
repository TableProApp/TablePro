import Combine
import Observation
import SwiftUI
import UIKit

final class TableProAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = TableProSceneDelegate.self
        return configuration
    }
}

enum LockCoverMode: Equatable {
    case locked
    case obscured
}

@Observable
final class LockCoverState {
    var mode: LockCoverMode = .obscured
}

final class TableProSceneDelegate: NSObject, UIWindowSceneDelegate, ObservableObject {
    var onDisconnect: (() -> Void)?

    private weak var windowScene: UIWindowScene?
    private var coverWindow: UIWindow?
    private let coverState = LockCoverState()

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        windowScene = scene as? UIWindowScene
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        onDisconnect?()
        onDisconnect = nil
    }

    func showCover(_ mode: LockCoverMode?, lockState: AppLockState) {
        guard let mode else {
            hideCover()
            return
        }
        guard let windowScene else { return }
        coverState.mode = mode
        let window = coverWindow ?? makeCoverWindow(in: windowScene, lockState: lockState)
        coverWindow = window
        for other in windowScene.windows where other !== window {
            other.endEditing(true)
        }
        window.isHidden = false
        window.makeKey()
    }

    private func hideCover() {
        guard let coverWindow, !coverWindow.isHidden else { return }
        coverWindow.isHidden = true
        windowScene?.windows.first { $0 !== coverWindow && !$0.isHidden }?.makeKey()
    }

    private func makeCoverWindow(in windowScene: UIWindowScene, lockState: AppLockState) -> UIWindow {
        let window = UIWindow(windowScene: windowScene)
        window.windowLevel = .alert + 1
        let host = UIHostingController(rootView: LockCoverView(state: coverState).environment(lockState))
        host.view.backgroundColor = .clear
        host.view.accessibilityViewIsModal = true
        window.rootViewController = host
        return window
    }
}

private struct LockCoverView: View {
    let state: LockCoverState

    var body: some View {
        switch state.mode {
        case .locked:
            LockScreenView()
        case .obscured:
            PrivacyCoverView()
        }
    }
}
