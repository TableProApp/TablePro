import BackgroundTasks
import os
import SwiftUI
import TableProAnalytics
import TableProDatabase
import TableProModels

@main
struct TableProMobileApp: App {
    static let backgroundSyncIdentifier = "com.TablePro.sync"
    private static let backgroundLogger = Logger(subsystem: "com.TablePro", category: "BackgroundSync")

    @UIApplicationDelegateAdaptor(TableProAppDelegate.self) private var appDelegate
    @State private var appState = AppState()
    @State private var lockState = AppLockState()
    @State private var syncTask: Task<Void, Never>?
    @State private var heartbeatService: AnalyticsHeartbeatService?
    @State private var heartbeatTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

    init() {
        ConnectionListTips.configure()
    }

    var body: some Scene {
        WindowGroup {
            SceneRootView(connectionManager: appState.connectionManager)
                .environment(appState)
                .environment(lockState)
                .hostKeyPrompt()
                .entraSignInPrompt()
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
                        await appState.syncCoordinator.sync()
                    }
                }
                startHeartbeatIfConsented()
            case .inactive:
                appState.backgroundRelease.prepareForSuspension()
            case .background:
                syncTask?.cancel()
                syncTask = nil
                stopHeartbeat()
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
            guard choice == true else {
                stopHeartbeat()
                return
            }
            startHeartbeatIfConsented()
        }
        .backgroundTask(.appRefresh(Self.backgroundSyncIdentifier)) {
            await runBackgroundSync()
        }
    }

    private func startHeartbeatIfConsented() {
        guard heartbeatTask == nil, appState.onboarding.isUsageDataEnabled else { return }
        let provider = IOSAnalyticsProvider.shared
        provider.attach(appState: appState)
        let service = AnalyticsHeartbeatService(provider: provider)
        heartbeatService = service
        heartbeatTask = service.startPeriodicHeartbeat()
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        heartbeatService = nil
    }

    private func scheduleBackgroundSync() {
        guard AppPreferences.isCloudSyncEnabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundSyncIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Self.backgroundLogger.warning("Failed to schedule background sync: \(error.localizedDescription, privacy: .public)")
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
        await appState.syncCoordinator.sync()
        Self.backgroundLogger.info("Background sync completed")
    }
}
