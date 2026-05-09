import CoreSpotlight
import SwiftUI
import TableProAnalytics
import TableProDatabase
import TableProModels

@main
struct TableProMobileApp: App {
    @State private var appState = AppState()
    @State private var lockState = AppLockState()
    @State private var syncTask: Task<Void, Never>?
    @State private var heartbeatService: AnalyticsHeartbeatService?
    @State private var heartbeatTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                Group {
                    if appState.hasCompletedOnboarding {
                        ConnectionListView()
                            .environment(appState)
                    } else {
                        OnboardingView()
                            .environment(appState)
                    }
                }
                .blur(radius: lockState.isLocked ? 20 : 0)
                .allowsHitTesting(!lockState.isLocked)

                if lockState.isLocked {
                    LockScreenView()
                        .environment(lockState)
                        .transition(.opacity)
                }
            }
            .animation(.default, value: lockState.isLocked)
            .onOpenURL { url in
                guard url.scheme == "tablepro",
                      url.host(percentEncoded: false) == "connect",
                      let uuidString = url.pathComponents.dropFirst().first,
                      let uuid = UUID(uuidString: uuidString) else { return }
                appState.pendingConnectionId = uuid
            }
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                      let uuid = UUID(uuidString: identifier) else { return }
                appState.pendingConnectionId = uuid
            }
            .onContinueUserActivity("com.TablePro.viewConnection") { activity in
                guard let connectionId = activity.userInfo?["connectionId"] as? String,
                      let uuid = UUID(uuidString: connectionId) else { return }
                appState.pendingConnectionId = uuid
            }
            .onContinueUserActivity("com.TablePro.viewTable") { activity in
                guard let connectionId = activity.userInfo?["connectionId"] as? String,
                      let uuid = UUID(uuidString: connectionId) else { return }
                appState.pendingConnectionId = uuid
                appState.pendingTableName = activity.userInfo?["tableName"] as? String
            }
        }
        .onChange(of: scenePhase) { _, phase in
            lockState.handleScenePhase(phase)
            switch phase {
            case .active:
                MemoryPressureMonitor.shared.start()
                syncTask?.cancel()
                syncTask = Task {
                    await appState.syncCoordinator.sync(
                        localConnections: appState.connections,
                        localGroups: appState.groups,
                        localTags: appState.tags
                    )
                }
                if heartbeatTask == nil {
                    let provider = IOSAnalyticsProvider.shared
                    provider.attach(appState: appState)
                    let service = AnalyticsHeartbeatService(provider: provider)
                    heartbeatService = service
                    heartbeatTask = service.startPeriodicHeartbeat()
                }
            case .background:
                syncTask?.cancel()
                syncTask = nil
                heartbeatTask?.cancel()
                heartbeatTask = nil
                heartbeatService = nil
                Task { await appState.connectionManager.disconnectAll() }
            default:
                break
            }
        }
    }
}
