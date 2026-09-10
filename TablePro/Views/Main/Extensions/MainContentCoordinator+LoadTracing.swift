//
//  MainContentCoordinator+LoadTracing.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    /// Captured when the trace begins rather than read when it ends. `TableLoadTracer` is one
    /// process-wide singleton and a coordinator belongs to one connection session, so an ending site
    /// would read whichever session happened to be current instead of the one that ran the load.
    var tableLoadEnvironment: TableLoadEnvironment {
        TableLoadEnvironment(
            databaseTypeId: connection.type.rawValue,
            usesSSH: connection.sshTunnelMode != .disabled,
            openTabCount: tabManager.tabs.count
        )
    }

    func traceExecutionStarted(_ token: TableLoadTraceToken?, epoch: Int, isAutoLoad: Bool) {
        guard let token else { return }
        TableLoadTracer.shared.stage(
            .executeStarted,
            token: token,
            detail: "epoch=\(epoch) isAutoLoad=\(isAutoLoad)"
        )
    }

    /// Ending the trace here is only right when it never got a query of its own. If it did, the result
    /// is still on its way back and has to be able to report against it, so the trace stays open and
    /// whatever the query does next closes it.
    func traceExecutionBlocked(tabId: UUID, site: String) {
        let tracer = TableLoadTracer.shared
        guard let token = tracer.activeToken(for: tabId) else { return }
        tracer.anomaly(
            .blockedByInFlightExecution,
            token: token,
            detail: "site=\(site) hasInFlightQuery=\(currentQueryTask != nil)"
        )
        guard !tracer.hasStartedExecution(token) else { return }
        tracer.finish(token: token, outcome: .blocked)
    }

    func traceNavigationAbandoned(tabId: UUID, outcome: TableLoadOutcome) {
        let tracer = TableLoadTracer.shared
        guard let token = tracer.activeToken(for: tabId), !tracer.hasStartedExecution(token) else { return }
        tracer.anomaly(.preparationAbandoned, token: token, detail: outcome.rawValue)
        tracer.finish(token: token, outcome: outcome)
    }

    /// The result's shape is handed over after both fetch stages are stamped, so sampling it for a
    /// size estimate cannot land inside the interval it is describing.
    func traceFetchCompleted(
        _ token: TableLoadTraceToken?,
        began: ContinuousClock.Instant,
        ended: ContinuousClock.Instant,
        result: QueryFetchResult
    ) {
        guard let token else { return }
        let tracer = TableLoadTracer.shared
        tracer.stage(.driverFetchBegin, token: token, at: began)
        tracer.stage(
            .driverFetchEnd,
            token: token,
            at: ended,
            detail: """
                rows=\(result.rows.count) cols=\(result.columns.count) \
                driverMs=\(Int(result.executionTime * 1_000))
                """
        )
        tracer.setResultMetrics(
            TableLoadResultMetrics(rows: result.rows, columnCount: result.columns.count),
            token: token
        )
    }

    func traceFetchCancelled(
        _ token: TableLoadTraceToken?,
        began: ContinuousClock.Instant,
        ended: ContinuousClock.Instant
    ) {
        guard let token else { return }
        let tracer = TableLoadTracer.shared
        tracer.stage(.driverFetchBegin, token: token, at: began)
        tracer.stage(.driverFetchEnd, token: token, at: ended)
        tracer.anomaly(.executionCancelled, token: token)
        tracer.finish(token: token, outcome: .cancelled)
    }

    func traceStaleResultDropped(_ token: TableLoadTraceToken?) {
        guard let token else { return }
        let tracer = TableLoadTracer.shared
        let owner = tracer.activeToken(for: token.tabId)
        tracer.anomaly(
            .staleResultDropped,
            token: token,
            detail: "tabOwnedBy=\(owner.map { "#\($0.sequence)" } ?? "none") cancelled=\(Task.isCancelled)"
        )
        tracer.finish(token: token, outcome: .staleDropped)
    }

    /// A result whose table no longer matches what the tab shows is the defect the user sees as
    /// "the grid filled with the table I navigated away from", so it is called out before the
    /// result is applied rather than inferred later from the row data.
    func traceApplyingResult(_ token: TableLoadTraceToken?, tabId: UUID) {
        guard let token else { return }
        let tracer = TableLoadTracer.shared
        let currentTable = tabManager.tabs.first(where: { $0.id == tabId })?.tableContext.tableName
        if let currentTable, currentTable != token.table {
            tracer.anomaly(
                .resultTableMismatch,
                token: token,
                detail: "resultTable=\(token.table) tabNowShows=\(currentTable)"
            )
        }
        tracer.stage(.applyResultBegin, token: token)
        tracer.beginApplyScope(token)
    }

    /// The trace for a query that has no navigation behind it, so re-executions on an already loaded
    /// tab (pagination, sort, filter, refresh, save-and-reload) still produce a timeline and can still
    /// report `blockedByInFlightExecution`.
    func adoptOrBeginExecutionTrace(tabId: UUID) -> TableLoadTraceToken? {
        let tracer = TableLoadTracer.shared
        if let existing = tracer.activeToken(for: tabId) { return existing }
        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }) else { return nil }
        return tracer.begin(
            tabId: tabId,
            table: tab.tableContext.tableName ?? tab.title,
            origin: .reExecute,
            environment: tableLoadEnvironment
        )
    }

    func traceConnectUnavailable(_ token: TableLoadTraceToken?) {
        guard let token else { return }
        let tracer = TableLoadTracer.shared
        tracer.anomaly(.connectionNotReady, token: token, detail: "site=ensureConnected")
        tracer.finish(token: token, outcome: .notConnected)
    }

    func traceExecutionFailed(_ token: TableLoadTraceToken?, error: Error) {
        guard let token else { return }
        TableLoadTracer.shared.finish(token: token, outcome: .failed, detail: "\(type(of: error))")
    }

    /// Ends the trace one run loop turn after the grid reload. `reloadData()` only invalidates,
    /// so the cell work it schedules runs later in the same turn; closing the trace on the next
    /// turn is what makes that cost visible instead of hiding it after the last stage.
    func scheduleTraceCompletion(_ token: TableLoadTraceToken?, outcome: TableLoadOutcome) {
        TableLoadTracer.shared.endApplyScope()
        guard let token else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let tracer = TableLoadTracer.shared
                tracer.stage(.mainRunLoopIdle, token: token)
                tracer.finish(token: token, outcome: outcome)
            }
        }
    }
}
