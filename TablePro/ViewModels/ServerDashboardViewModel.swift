import Combine
import Foundation
import os

@MainActor
final class ServerDashboardViewModel: ObservableObject {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "ServerDashboard")

    // MARK: - Configuration

    let connectionId: UUID
    let databaseType: DatabaseType
    @Published private(set) var provider: ServerDashboardQueryProvider?

    // MARK: - Data

    @Published var sessions: [DashboardSession] = [] {
        didSet { dropEndedSessionsFromSelection() }
    }
    @Published var metrics: [DashboardMetric] = []
    @Published var slowQueries: [DashboardSlowQuery] = []

    // MARK: - Refresh State

    @Published var refreshInterval: DashboardRefreshInterval = .fiveSeconds {
        didSet {
            guard oldValue != refreshInterval else { return }
            if refreshTask != nil || refreshInterval != .off {
                startAutoRefresh()
            }
        }
    }

    @Published var isPaused: Bool = false
    @Published var isRefreshing: Bool = false
    @Published var lastRefreshDate: Date?
    @Published var panelErrors: [DashboardPanel: String] = [:]

    // MARK: - Sort State

    @Published var sessionSortOrder: [KeyPathComparator<DashboardSession>] = [
        KeyPathComparator(\DashboardSession.durationSeconds, order: .reverse),
    ]

    // MARK: - Kill / Cancel Confirmation

    @Published var showKillConfirmation: Bool = false
    @Published var pendingKillSession: DashboardSession?
    @Published var showCancelConfirmation: Bool = false
    @Published var pendingCancelSession: DashboardSession?
    @Published var actionError: String?

    // MARK: - Selection

    /// Kept here, not in the sessions pane, so the refresh that stops listing a session also drops it.
    let sessionSelection = StructureListSelection<String>()

    // MARK: - Private

    nonisolated(unsafe) private var refreshTask: Task<Void, Never>?
    private let services: AppServices
    private var providerServerVersion: String?
    private var hasAdoptedServerVersion = false

    // MARK: - Computed Properties

    var supportedPanels: Set<DashboardPanel> {
        provider?.supportedPanels ?? []
    }

    var isSupported: Bool {
        provider != nil
    }

    func canKill(_ session: DashboardSession) -> Bool {
        provider?.canKill(session) ?? false
    }

    func canCancel(_ session: DashboardSession) -> Bool {
        provider?.canCancel(session) ?? false
    }

    // A server hands a freed session id to its next connection, so a kept id would select that one.
    private func dropEndedSessionsFromSelection() {
        let kept = sessionSelection.ids.intersection(sessions.map(\.id))
        guard kept != sessionSelection.ids else { return }
        sessionSelection.ids = kept
    }

    // MARK: - Initialization

    init(connectionId: UUID, databaseType: DatabaseType, services: AppServices = .live) {
        self.connectionId = connectionId
        self.databaseType = databaseType
        self.provider = ServerDashboardQueryProviderFactory.provider(for: databaseType)
        self.services = services
    }

    deinit {
        refreshTask?.cancel()
    }

    // MARK: - Auto Refresh

    func startAutoRefresh() {
        refreshTask?.cancel()

        guard refreshInterval != .off else {
            refreshTask = nil
            return
        }

        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.isPaused {
                    await self.refreshNow()
                }
                let interval = self.refreshInterval.rawValue
                guard interval > 0 else { break }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
    }

    // MARK: - Data Fetching

    /// The provider is built once per server version, because it also answers `supportedPanels`
    /// and whether each listed session can be terminated or cancelled between refreshes.
    private func adoptProvider(forServerVersion serverVersion: String?) {
        guard serverVersion != providerServerVersion || !hasAdoptedServerVersion else { return }
        providerServerVersion = serverVersion
        hasAdoptedServerVersion = true
        guard let resolved = ServerDashboardQueryProviderFactory.provider(
            for: databaseType, serverVersion: serverVersion
        ) else { return }
        provider = resolved
    }

    func refreshNow() async {
        guard !isRefreshing else { return }
        guard provider != nil else {
            Self.logger.warning("No query provider available for \(self.databaseType.rawValue)")
            return
        }

        guard let liveDriver = services.databaseManager.driver(for: connectionId) else { return }
        adoptProvider(forServerVersion: liveDriver.serverVersion)
        guard let provider else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        let execute: (String) async throws -> QueryResult = { [connectionId, services] query in
            guard let driver = services.databaseManager.driver(for: connectionId) else {
                throw DatabaseError.connectionFailed(
                    String(localized: "No active connection")
                )
            }
            return try await driver.execute(query: query)
        }

        var newPanelErrors: [DashboardPanel: String] = [:]

        if provider.supportedPanels.contains(.activeSessions) {
            do {
                sessions = try await provider.fetchSessions(execute: execute)
                sessions.sort(using: sessionSortOrder)
            } catch {
                Self.logger.warning("Failed to fetch sessions: \(error.localizedDescription)")
                newPanelErrors[.activeSessions] = error.localizedDescription
            }
        }

        if provider.supportedPanels.contains(.serverMetrics) {
            do {
                metrics = try await provider.fetchMetrics(execute: execute)
            } catch {
                Self.logger.warning("Failed to fetch metrics: \(error.localizedDescription)")
                newPanelErrors[.serverMetrics] = error.localizedDescription
            }
        }

        if provider.supportedPanels.contains(.slowQueries) {
            do {
                slowQueries = try await provider.fetchSlowQueries(execute: execute)
            } catch {
                Self.logger.warning("Failed to fetch slow queries: \(error.localizedDescription)")
                newPanelErrors[.slowQueries] = error.localizedDescription
            }
        }

        panelErrors = newPanelErrors
        lastRefreshDate = Date()
    }

    // MARK: - Kill Session

    func confirmKillSession(_ session: DashboardSession) {
        pendingKillSession = session
        showKillConfirmation = true
    }

    static func killConfirmationMessage(for session: DashboardSession) -> String {
        guard !session.user.isEmpty else {
            return String(format: String(localized: "Terminate session %@? Any running queries will be aborted."), session.id)
        }
        return String(
            format: String(localized: "Terminate session %1$@ (user %2$@)? Any running queries will be aborted."),
            session.id,
            session.user
        )
    }

    func executeKillSession() async {
        guard let processId = pendingKillSession?.id else { return }
        pendingKillSession = nil
        showKillConfirmation = false

        guard let sql = provider?.killSessionSQL(processId: processId) else { return }

        do {
            guard let driver = services.databaseManager.driver(for: connectionId) else {
                throw DatabaseError.connectionFailed(
                    String(localized: "No active connection")
                )
            }
            _ = try await driver.execute(query: sql)
            Self.logger.info("Killed session \(processId)")
            await refreshNow()
        } catch {
            Self.logger.error("Failed to kill session \(processId): \(error.localizedDescription)")
            actionError = error.localizedDescription
        }
    }

    // MARK: - Cancel Query

    func confirmCancelQuery(_ session: DashboardSession) {
        pendingCancelSession = session
        showCancelConfirmation = true
    }

    static func cancelConfirmationMessage(for session: DashboardSession) -> String {
        guard !session.user.isEmpty else {
            return String(format: String(localized: "Cancel the running query for session %@?"), session.id)
        }
        return String(
            format: String(localized: "Cancel the running query for session %1$@ (user %2$@)?"),
            session.id,
            session.user
        )
    }

    func executeCancelQuery() async {
        guard let processId = pendingCancelSession?.id else { return }
        pendingCancelSession = nil
        showCancelConfirmation = false

        guard let sql = provider?.cancelQuerySQL(processId: processId) else { return }

        do {
            guard let driver = services.databaseManager.driver(for: connectionId) else {
                throw DatabaseError.connectionFailed(
                    String(localized: "No active connection")
                )
            }
            _ = try await driver.execute(query: sql)
            Self.logger.info("Cancelled query for process \(processId)")
            await refreshNow()
        } catch {
            Self.logger.error("Failed to cancel query for process \(processId): \(error.localizedDescription)")
            actionError = error.localizedDescription
        }
    }
}
