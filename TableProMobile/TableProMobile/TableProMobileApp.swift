//
//  TableProMobileApp.swift
//  TableProMobile
//

import CoreSpotlight
import SwiftUI
import TableProDatabase
import TableProModels

@main
struct TableProMobileApp: App {
    @State private var appState = AppState()
    @State private var syncTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if appState.hasCompletedOnboarding {
                    ConnectionListView()
                        .environment(appState)
                } else {
                    OnboardingView()
                        .environment(appState)
                }
            }
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
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                syncTask?.cancel()
                syncTask = Task {
                    await appState.syncCoordinator.sync(
                        localConnections: appState.connections,
                        localGroups: appState.groups,
                        localTags: appState.tags
                    )
                }
            case .background:
                Task { await appState.connectionManager.disconnectAll() }
            default:
                break
            }
        }
    }
}
