import Combine
import Observation
import os
import SwiftUI
import TableProSyncTransport
import UIKit

final class TableProAppDelegate: NSObject, UIApplicationDelegate {
    // Set in the app's init, which runs before the system hands this delegate a launch or a notification.
    static weak var appState: AppState?

    private static let logger = Logger(subsystem: "com.TablePro", category: "Sync")

    // iOS ends an app that has not answered a notification in 30 seconds; a run still going finishes when the app next runs.
    private static let notificationBudget: Duration = .seconds(25)

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Self.appState?.syncCoordinator.registerForPushesIfEnabled()
        return true
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        Self.logger.warning("Push registration failed: \(error.localizedDescription, privacy: .private)")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        guard SyncPushSubscription.announcesChange(userInfo), let appState = Self.appState else { return .noData }
        let run = Task { await appState.syncFromBackground(.remoteChange) }
        guard let ran = await Self.value(of: run, within: Self.notificationBudget) else { return .failed }
        guard ran else { return .noData }
        return appState.syncCoordinator.status.error == nil ? .newData : .failed
    }

    private static func value<Value: Sendable>(of task: Task<Value, Never>, within budget: Duration) async -> Value? {
        await withCheckedContinuation { continuation in
            let answer = FirstAnswer(continuation)
            let timer = Task {
                try? await Task.sleep(for: budget)
                answer.give(nil)
            }
            Task {
                let value = await task.value
                timer.cancel()
                answer.give(value)
            }
        }
    }

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

private final class FirstAnswer<Value: Sendable> {
    private var continuation: CheckedContinuation<Value?, Never>?

    init(_ continuation: CheckedContinuation<Value?, Never>) {
        self.continuation = continuation
    }

    func give(_ value: Value?) {
        continuation?.resume(returning: value)
        continuation = nil
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
