import SwiftUI
import TableProDatabase

/// One per scene, because a coordinator carries the screen's own tab, navigation path and connect
/// attempt. Two iPad windows on the same connection are two screens, not one.
struct SceneRootView: View {
    @Environment(AppState.self) private var appState
    @State private var coordinatorStore: ConnectionCoordinatorStore

    init(connectionManager: ConnectionManager) {
        _coordinatorStore = State(
            initialValue: ConnectionCoordinatorStore(connectionManager: connectionManager)
        )
    }

    var body: some View {
        Group {
            if appState.hasCompletedOnboarding {
                ConnectionListView()
            } else {
                OnboardingView()
            }
        }
        .environment(coordinatorStore)
        .onChange(of: appState.connections) { previous, current in
            coordinatorStore.reconcile(from: previous, to: current)
        }
    }
}
