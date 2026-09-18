import CoreSpotlight
import SwiftUI
import TableProDatabase
import TableProModels

struct SceneRootView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppLockState.self) private var lockState
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var sceneDelegate: TableProSceneDelegate
    @State private var coordinatorStore: ConnectionCoordinatorStore
    @State private var presenter = ScenePresenter()

    init(connectionManager: ConnectionManager) {
        _coordinatorStore = State(
            initialValue: ConnectionCoordinatorStore(connectionManager: connectionManager)
        )
    }

    var body: some View {
        ConnectionListView()
            .environment(coordinatorStore)
            .environment(presenter)
            .onChange(of: appState.connections) { previous, current in
                coordinatorStore.reconcile(from: previous, to: current)
            }
            .onChange(of: appState.sampleResetRevision) { _, _ in
                for sample in appState.connections where sample.isSample {
                    coordinatorStore.invalidate(sample.id, droppingSession: false)
                }
            }
            .onOpenURL { url in
                guard let intent = SceneIntent.parse(url: url) else { return }
                presenter.receive(intent)
            }
            .onContinueUserActivity(CSSearchableItemActionType, perform: receive)
            .onContinueUserActivity(SceneIntent.viewConnectionActivity, perform: receive)
            .onContinueUserActivity(SceneIntent.viewTableActivity, perform: receive)
            .onAppear {
                sceneDelegate.onDisconnect = { [presenter, appState] in
                    presenter.releaseLaunchClaim(appState: appState)
                }
                updateLockCover()
            }
            .onChange(of: lockState.isLocked) { _, _ in
                updateLockCover()
            }
            .onChange(of: scenePhase) { _, _ in
                updateLockCover()
            }
    }

    private func receive(_ activity: NSUserActivity) {
        guard let intent = SceneIntent.parse(activityType: activity.activityType, userInfo: activity.userInfo) else {
            return
        }
        presenter.receive(intent)
    }

    private func updateLockCover() {
        guard !TestRuntime.isActive else { return }
        sceneDelegate.showCover(lockCoverMode, lockState: lockState)
    }

    private var lockCoverMode: LockCoverMode? {
        if lockState.isLocked {
            return .locked
        }
        guard scenePhase != .active, AppLockState.isLockEnabled, lockState.biometry != .unavailable else {
            return nil
        }
        return .obscured
    }
}
