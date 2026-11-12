import AppIntents
import BackgroundTasks
import os
import SwiftUI
import TableProDatabase
import TableProModels
import TableProSyncTransport

@main
struct TableProMobileApp: App {
    static let backgroundSyncIdentifier = "com.TablePro.sync"
    private static let backgroundLogger = Logger(subsystem: "com.TablePro", category: "BackgroundSync")

    @UIApplicationDelegateAdaptor(TableProAppDelegate.self) private var appDelegate
    @State private var appState: AppState
    @State private var lockState: AppLockState
    @State private var syncTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

    init() {
        ConnectionListTips.configure()
        let appState = AppState()
        _appState = State(initialValue: appState)
        // At launch, so a connection opened before the scene first turns active still sends its first-use event.
        if !TestRuntime.isActive {
            Self.startTelemetry(appState: appState)
        }
        let lockState = AppLockState()
        _lockState = State(initialValue: lockState)
        AppDependencyManager.shared.add(dependency: lockState)
    }

    var body: some Scene {
        WindowGroup {
            SceneRootView(
                connectionManager: appState.connectionManager,
                isLockedAtLaunch: lockState.isLocked
            )
                .environment(appState)
                .environment(lockState)
        }
        .commands {
            QueryCommands()
        }
        .onChange(of: scenePhase) { _, phase in
            guard !TestRuntime.isActive else { return }
            lockState.handleScenePhase(phase)
            switch phase {
            case .active:
                Task { await appState.queryActivities.reapOrphans() }
                appState.backgroundRelease.cancelPreparation()
                MemoryPressureMonitor.shared.start()
                appState.retryLoadIfFailed()
                if appState.onboarding.isCloudSyncEnabled && appState.loadStatus == .ready {
                    syncTask?.cancel()
                    syncTask = Task {
                        await appState.syncCoordinator.syncOnSceneActivation()
                    }
                }
                Telemetry.shared.sceneBecameActive()
            case .inactive:
                appState.backgroundRelease.prepareForSuspension()
            case .background:
                syncTask?.cancel()
                syncTask = nil
                Telemetry.shared.sceneEnteredBackground()
                Task {
                    let released = await appState.backgroundRelease.releaseForSuspension()
                    for connectionId in released {
                        await appState.queryActivities.endEverything(forConnection: connectionId, outcome: .interrupted)
                    }
                }
                scheduleBackgroundSync()
            default:
                break
            }
        }
        .onChange(of: appState.onboarding.usageDataChoice) { _, choice in
            guard !TestRuntime.isActive else { return }
            Telemetry.shared.setEnabled(choice == true)
        }
        .backgroundTask(.appRefresh(Self.backgroundSyncIdentifier)) {
            await runBackgroundSync()
        }
    }

    private static func startTelemetry(appState: AppState) {
        Telemetry.shared.start(sharesUsageData: appState.onboarding.isUsageDataEnabled) {
            appState.connections
                .filter { appState.connectionManager.session(for: $0.id) != nil }
                .map(\.type.rawValue)
        }
    }

    private func scheduleBackgroundSync() {
        guard AppPreferences.isCloudSyncEnabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundSyncIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Self.backgroundLogger.warning("Failed to schedule background sync: \(error.localizedDescription, privacy: .private)")
        }
    }

    @Sendable
    private func runBackgroundSync() async {
        scheduleBackgroundSync()
        guard AppPreferences.isCloudSyncEnabled else { return }
        await MainActor.run { appState.retryLoadIfFailed() }
        let status = await MainActor.run { appState.loadStatus }
        guard status == .ready else {
            Self.backgroundLogger.warning("Background sync skipped: persistence load not ready (likely device locked)")
            return
        }
        Self.backgroundLogger.info("Background sync starting")
        await appState.syncCoordinator.sync(.activation)
        Self.backgroundLogger.info("Background sync completed")
    }
}
