//
//  QueryExecutionCoordinator+RunLog.swift
//  TablePro
//

import Foundation

/// The run log is written beside the results, never instead of them: each path installs its results as it always
/// has and then records what every statement came to here.
extension QueryExecutionCoordinator {
    /// A run whose claim was settled writes here below its settle gate. A run the user stopped settles nothing, so it
    /// writes here too, and the two guards keep it from covering a newer run: a run still executing on the tab will
    /// write its own log, and one that already finished started later than this one.
    func recordRunLog(
        _ entries: [QueryRunLogEntry],
        tabId: UUID,
        startedAt: ContinuousClock.Instant,
        notice: String? = nil
    ) {
        guard !entries.isEmpty, !parent.tabExecution.isExecuting(tabId),
              let tab = parent.tabManager.tabs.first(where: { $0.id == tabId }),
              tab.tabType == .query else { return }
        let log = QueryRunLog(startedAt: startedAt, entries: entries, notice: notice)
        guard tab.display.admitsRunLog(log) else { return }
        parent.tabManager.mutate(tabId: tabId) { $0.display.installRunLog(log) }
    }

    /// The single-statement paths install one result and make it active, so the entry reads it back from the tab.
    func recordStatementRun(_ statement: String, tabId: UUID, startedAt: ContinuousClock.Instant) {
        guard let resultSet = parent.tabManager.tabs.first(where: { $0.id == tabId })?.display.activeResultSet else {
            return
        }
        recordRunLog(
            [QueryRunLogEntry(statement: statement, resultSet: resultSet)],
            tabId: tabId,
            startedAt: startedAt
        )
    }

    /// Reads the message the failure left on the tab, so the log says exactly what the banner says.
    func recordStatementFailure(
        _ statement: String,
        error: Error,
        tabId: UUID,
        startedAt: ContinuousClock.Instant
    ) {
        let message = parent.tabManager.tabs.first(where: { $0.id == tabId })?.execution.errorMessage
            ?? error.localizedDescription
        recordRunLog([.failed(statement, message: message)], tabId: tabId, startedAt: startedAt)
    }

    func recordStatementCancelled(_ statement: String, tabId: UUID, startedAt: ContinuousClock.Instant) {
        recordRunLog([.cancelled(statement)], tabId: tabId, startedAt: startedAt)
    }
}
