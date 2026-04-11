import Foundation
import os

@MainActor
@Observable
final class ServerDashboardViewModel {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ServerDashboard")

    // MARK: - Configuration

    let connectionId: UUID
    let databaseType: DatabaseType
    private(set) var provider: ServerDashboardQueryProvider?

    // MARK: - Data

    var sessions: [DashboardSession] = []
    var metrics: [DashboardMetric] = []
    var slowQueries: [DashboardSlowQuery] = []

    // MARK: - Refresh State

    var refreshInterval: DashboardRefreshInterval = .fiveSeconds {
        didSet {
            guard oldValue != refreshInterval else { return }
            if refreshTask != nil || refreshInterval != .off {
                startAutoRefresh()
            }
        }
    }

    var isPaused: Bool = false
    var isRefreshing: Bool = false
    var lastRefreshDate: Date?
    var panelErrors: [DashboardPanel: String] = [:]

    // MARK: - Sort State

    var sessionSortOrder: [KeyPathComparator<DashboardSession>] = [
        KeyPathComparator(\DashboardSession.durationSeconds, order: .reverse),
    ]

    // MARK: - Kill / Cancel Confirmation

    var showKillConfirmation: Bool = false
    var pendingKillProcessId: String?
    var showCancelConfirmation: Bool = false
    var pendingCancelProcessId: String?
    var actionError: String?

    // MARK: - Private

    @ObservationIgnored nonisolated(unsafe) private var refreshTask: Task<Void, Never>?

    // MARK: - Computed Properties

    var supportedPanels: Set<DashboardPanel> {
        provider?.supportedPanels ?? []
    }

    var isSupported: Bool {
        provider != nil
    }

    var canKillSessions: Bool {
        provider?.killSessionSQL(processId: "0") != nil
    }

    var canCancelQueries: Bool {
        provider?.cancelQuerySQL(processId: "0") != nil
    }

    // MARK: - Initialization

    init(connectionId: UUID, databaseType: DatabaseType) {
        self.connectionId = connectionId
        self.databaseType = databaseType
        self.provider = ServerDashboardQueryProviderFactory.provider(for: databaseType)
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

    func refreshNow() async {
        guard !isRefreshing else { return }
        guard let provider else {
            Self.logger.warning("No query provider available for \(self.databaseType.rawValue)")
            return
        }

        // Skip silently if connection is not ready yet — the refresh loop will retry
        guard DatabaseManager.shared.driver(for: connectionId) != nil else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        let execute: (String) async throws -> QueryResult = { [connectionId] query in
            guard let driver = DatabaseManager.shared.driver(for: connectionId) else {
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

    func confirmKillSession(processId: String) {
        pendingKillProcessId = processId
        showKillConfirmation = true
    }

    func executeKillSession() async {
        guard let processId = pendingKillProcessId else { return }
        pendingKillProcessId = nil
        showKillConfirmation = false

        guard let sql = provider?.killSessionSQL(processId: processId) else { return }

        do {
            guard let driver = DatabaseManager.shared.driver(for: connectionId) else {
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

    func confirmCancelQuery(processId: String) {
        pendingCancelProcessId = processId
        showCancelConfirmation = true
    }

    func executeCancelQuery() async {
        guard let processId = pendingCancelProcessId else { return }
        pendingCancelProcessId = nil
        showCancelConfirmation = false

        guard let sql = provider?.cancelQuerySQL(processId: processId) else { return }

        do {
            guard let driver = DatabaseManager.shared.driver(for: connectionId) else {
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
