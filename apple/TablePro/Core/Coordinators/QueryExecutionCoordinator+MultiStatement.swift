//
//  QueryExecutionCoordinator+MultiStatement.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar

// A statement's table name and rows, built away from the main actor for the result it becomes.
struct StatementRows: Sendable {
    let tableName: String?
    let prepared: TableRows.PreparedRows
}

// The names hold only while the session still reads them the same way, so the build keeps the reading it used.
// A statement whose rows no result shows has nothing built.
struct StatementRowsBuild: Sendable {
    let reading: TableNameReading
    let statements: [StatementRows?]

    func statement(at index: Int, readBy current: TableNameReading) -> StatementRows? {
        guard current == reading, statements.indices.contains(index) else { return nil }
        return statements[index]
    }
}

extension QueryExecutionCoordinator {
    func executeMultipleStatements(
        _ statements: [SQLStatementScanner.ExecutableStatement],
        bypassRowLimit: Bool = false,
        onTab target: UUID? = nil
    ) {
        executeMultipleStatementsWithParameters(
            statements, parameters: [], bypassRowLimit: bypassRowLimit, onTab: target
        )
    }

    // The rest of a run, cut again once a statement changed how the session reads literals, in tab coordinates.
    nonisolated static func remainingStatements(
        in text: String,
        after ran: NSRange,
        through end: Int,
        grammar: SQLLexicalGrammar
    ) -> [SQLStatementScanner.ExecutableStatement] {
        let source = text as NSString
        let start = NSMaxRange(ran)
        guard start < end, end <= source.length else { return [] }
        let rest = source.substring(with: NSRange(location: start, length: end - start))
        return SQLStatementScanner.executableStatements(in: rest, grammar: grammar).map { $0.offset(by: start) }
    }

    // False once the editor's text no longer holds each statement where the run found it.
    nonisolated static func scriptHolds(_ statements: [SQLStatementScanner.ExecutableStatement], in text: String) -> Bool {
        let source = text as NSString
        return statements.allSatisfy { statement in
            NSMaxRange(statement.range) <= source.length && source.substring(with: statement.range) == statement.sql
        }
    }

    // A context is Read-Only's, and every call below carries it.
    func executeStatement(
        rowCap: Int?,
        originalSQL: String,
        driver: DatabaseDriver,
        parameters: [Any?]? = nil,
        context: PluginStatementContext? = nil
    ) async throws -> QueryResult {
        if let context {
            return try await executeStatement(
                rowCap: rowCap, originalSQL: originalSQL, driver: driver, parameters: parameters, carrying: context
            )
        }
        if rowCap != nil {
            if parameters == nil, let cap = rowCap, cap > 0,
               let bounded = try await driver.executeBoundedQuery(query: originalSQL, rowCap: cap) {
                return bounded
            }
            return try await driver.executeUserQuery(query: originalSQL, rowCap: rowCap, parameters: parameters)
        }
        if let parameters {
            return try await driver.executeParameterized(query: originalSQL, parameters: parameters)
        }
        return try await driver.execute(query: originalSQL)
    }

    private func executeStatement(
        rowCap: Int?,
        originalSQL: String,
        driver: DatabaseDriver,
        parameters: [Any?]?,
        carrying context: PluginStatementContext
    ) async throws -> QueryResult {
        if rowCap != nil {
            if parameters == nil, let cap = rowCap, cap > 0,
               let bounded = try await driver.executeBoundedQuery(query: originalSQL, rowCap: cap, context: context) {
                return bounded
            }
            return try await driver.executeUserQuery(
                query: originalSQL, rowCap: rowCap, parameters: parameters, context: context
            )
        }
        if let parameters {
            return try await driver.executeParameterized(query: originalSQL, parameters: parameters, context: context)
        }
        return try await driver.execute(query: originalSQL, context: context)
    }

    func makeStatementResultSet(
        result: QueryResult,
        sql: String,
        index: Int,
        baseQuery: String?,
        baseQueryParameterValues: [TypedParameterValue?]? = nil,
        namedParameterStatement: NamedParameterStatement? = nil,
        tabId: UUID,
        anchor: StatementAnchor? = nil,
        built: StatementRows? = nil
    ) -> ResultSet {
        let tableName = if let built { built.tableName } else { parent.extractTableName(from: sql) }
        let resultSet = ResultSet(
            label: ResultSet.label(tableName: tableName, anchor: anchor, index: index),
            tableRows: statementTableRows(result, tableName: tableName, tabId: tabId, built: built?.prepared)
        )
        resultSet.statementAnchor = anchor
        resultSet.executionTime = result.executionTime
        resultSet.rowsAffected = result.rowsAffected
        resultSet.statusMessage = result.statusMessage
        resultSet.serverOutput = result.serverOutput
        if !result.columns.isEmpty {
            resultSet.isTruncated = result.isTruncated
            resultSet.baseQuery = baseQuery
            resultSet.baseQueryParameterValues = baseQueryParameterValues
            resultSet.namedParameterStatement = namedParameterStatement
        }
        resultSet.origin = statementOrigin(sql: sql, tabId: tabId, producesRows: !result.columns.isEmpty)
        return resultSet
    }

    // The rows built off the main actor when the masks they were built with still apply, else built here.
    func statementTableRows(_ result: QueryResult, tableName: String?, tabId: UUID, built: TableRows.PreparedRows?) -> TableRows {
        let columns = result.columns.map { String($0) }
        let shape = TableRows.RowShape(
            columns: columns,
            masks: parent.columnMasks(forTabId: tabId, table: tableName, columns: columns, columnTypes: result.columnTypes),
            exportPolicy: parent.exportMaskingPolicy(forTabId: tabId),
            exportTable: tableName
        )
        let prepared = built.flatMap { $0.fits(shape) && $0.rows.count == result.rows.count ? $0 : nil } ?? TableRows.prepare(
            result.rows,
            exportDocuments: result.exportDocuments,
            absentCells: result.absentCells,
            shape: shape
        )
        return TableRows.from(prepared: prepared, columnTypes: result.columnTypes, columnOrigins: result.columnOrigins)
    }

    // A nil sql is a result no statement names, which reads no table. A nil entry builds nothing.
    func buildStatementRows(_ statements: [(sql: String?, result: QueryResult)?], tabId: UUID) async -> StatementRowsBuild {
        let reveals = parent.tabManager.tabs.first { $0.id == tabId }?.revealsMaskedValues == true
        return await Self.statementRows(
            statements,
            reading: parent.tableNameReading,
            policy: reveals ? .none : parent.maskingPolicy
        )
    }

    // A run of 300 SELECTs holds 300 capped results, too many rows to build on the main actor. A Stop keeps them, so
    // this build runs to the end.
    @concurrent
    nonisolated static func statementRows(
        _ statements: [(sql: String?, result: QueryResult)?],
        reading: TableNameReading,
        policy: MaskingPolicy
    ) async -> StatementRowsBuild {
        StatementRowsBuild(reading: reading, statements: statements.map { entry -> StatementRows? in
            guard let entry else { return nil }
            let (sql, result) = entry
            let tableName = sql.flatMap(reading.tableName(in:))
            let shape = TableRows.RowShape(
                columns: result.columns,
                masks: policy.columnMasks(table: tableName, columns: result.columns, columnTypes: result.columnTypes),
                exportPolicy: policy,
                exportTable: tableName
            )
            return StatementRows(
                tableName: tableName,
                prepared: TableRows.prepare(
                    result.rows, exportDocuments: result.exportDocuments, absentCells: result.absentCells, shape: shape
                )
            )
        })
    }

    static let summaryMessageLimit = 5

    // The statements of one run that returned no rows, as one result: rows affected and time added
    // up, server output in the order it was printed.
    func makeRunSummaryResultSet(_ parts: [RunSummaryPart]) -> ResultSet {
        let count = parts.count.formatted()
        let resultSet = ResultSet(label: String(format: String(localized: "%@ Statements"), count))
        resultSet.rowsAffected = parts.reduce(0) { $0 + $1.rowsAffected }
        resultSet.executionTime = parts.reduce(0) { $0 + $1.executionTime }
        // A driver's own message (a warning, a server reply) stays, each once, after the count; a long script's
        // varied replies are cut to the first few.
        var seen: Set<String> = []
        var messages: [String] = []
        var unshown = 0
        for message in parts.compactMap(\.statusMessage) where !message.isEmpty && seen.insert(message).inserted {
            if messages.count < Self.summaryMessageLimit {
                messages.append(message)
            } else {
                unshown += 1
            }
        }
        if unshown == 1 {
            messages.append(String(localized: "1 more message."))
        } else if unshown > 1 {
            messages.append(String(format: String(localized: "%@ more messages."), unshown.formatted()))
        }
        resultSet.statusMessage = ([String(format: String(localized: "Ran %@ statements that returned no rows."), count)] + messages)
            .joined(separator: " ")
        resultSet.serverOutput = PluginServerOutput(
            lines: parts.flatMap(\.serverOutput.lines),
            isTruncated: parts.contains { $0.serverOutput.isTruncated }
        )
        return resultSet
    }

    func appendDroppedNotice(of plan: RunResultPlan, to resultSets: [ResultSet]) {
        guard let notice = plan.droppedNotice else { return }
        for resultSet in resultSets {
            resultSet.statusMessage = [resultSet.statusMessage, notice]
                .compactMap { $0?.isEmpty == false ? $0 : nil }
                .joined(separator: " ")
        }
    }

    /// Each statement in a multi-statement run targets its own table, so each result carries its
    /// own identity. Nothing fetches key columns for these statements, so the origin says so and
    /// the result is read-only until something does. Inheriting the previous run's keys made an
    /// UPDATE match by another table's key names, and calling them "no keys" would hand the
    /// generator a whole-row WHERE that changes every duplicate row.
    private func statementOrigin(sql: String, tabId: UUID, producesRows: Bool) -> ResultOrigin? {
        guard let tab = parent.tabManager.tabs.first(where: { $0.id == tabId }) else { return nil }
        let resolved = parent.resolveTableEditability(tab: tab, sql: sql)
        return ResultOrigin(
            tableName: resolved.tableName,
            schemaName: tab.tableContext.schemaName,
            databaseName: historyDatabaseName(tabId: tabId),
            primaryKeyColumns: [],
            isEditable: resolved.isEditable && producesRows,
            isView: tab.tableContext.isView,
            objectType: tab.tableContext.objectType,
            keysResolved: false
        )
    }

    /// `unresolvedOutcome` is what a statement whose commit went unanswered carries. The statement
    /// itself succeeded, so its rows and its timing are real, but whether the server kept it is not
    /// something anything here can find out, and a plain success badge would say it did.
    func recordStatementHistory(
        sql: String,
        result: QueryResult,
        connection: DatabaseConnection,
        databaseName: String,
        parameterValues: [QueryParameter]? = nil,
        unresolvedOutcome: String? = nil
    ) {
        let historySQL = sql.hasSuffix(";") ? sql : sql + ";"
        recordHistory(
            QueryHistoryRecordRequest(
                query: historySQL,
                connectionId: connection.id,
                databaseName: databaseName,
                databaseType: connection.type,
                source: .editor,
                executionTime: result.executionTime,
                rowCount: result.rows.count,
                wasSuccessful: unresolvedOutcome == nil,
                errorMessage: unresolvedOutcome,
                timing: result.resolvedTiming
            )
        )
    }

    /// The settle gate, the task retirement, the history and the outcome notification belong to the
    /// caller: a stopped run has already settled its claim and reports a cancellation rather than a
    /// success, and still shows the results of the statements its plan could not take back.
    ///
    /// `sessionNotice` is the one thing a successful run may still have to say: a batch that joined
    /// a transaction the user already had open committed nothing, and nothing else in the window
    /// reports an open transaction.
    func presentMultiStatementResults(
        tabId: UUID,
        timing: PluginQueryTiming,
        totalRowsAffected: Int,
        newResultSets: [ResultSet],
        sessionNotice: String?
    ) {
        let cumulativeTime = timing.total
        parent.toolbarState.recordQueryTiming(timing, for: tabId)

        guard let idx = parent.tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            return
        }

        // The footer reads the active result's own message, so the batch's notice goes on every result it produced.
        if let sessionNotice {
            for resultSet in newResultSets {
                resultSet.statusMessage = [resultSet.statusMessage, sessionNotice]
                    .compactMap { $0?.isEmpty == false ? $0 : nil }
                    .joined(separator: " ")
            }
        }

        let currentTab = parent.tabManager.tabs[idx]
        let activeResult = newResultSets.last
        let activeOrigin = activeResult?.origin

        parent.flushBufferToActiveResult(tabId: currentTab.id, pinnedOnly: true)
        parent.setActiveTableRows(activeResult?.tableRows ?? TableRows(), for: currentTab.id)

        parent.tabManager.mutate(at: idx) { tab in
            if tab.tabType == .query {
                tab.tableContext.tableName = activeOrigin?.tableName
                tab.tableContext.schemaName = activeOrigin?.schemaName
                tab.tableContext.primaryKeyColumns = activeOrigin?.primaryKeyColumns ?? []
                tab.tableContext.isEditable = activeOrigin?.isEditable ?? false
            } else if activeOrigin?.tableName == nil {
                tab.tableContext.isEditable = false
            }

            tab.schemaVersion += 1
            tab.execution.executionTime = cumulativeTime
            tab.execution.rowsAffected = totalRowsAffected
            tab.execution.lastExecutedAt = Date()
            tab.execution.errorMessage = nil
            tab.execution.statusMessage = sessionNotice

            tab.display.replaceUnpinnedResults(with: newResultSets)
            if tab.display.isResultsCollapsed {
                tab.display.isResultsCollapsed = false
            }

            let activeResultSet = activeResult
            if activeResultSet?.isTruncated == true {
                tab.pagination.hasMoreRows = true
                tab.pagination.isLoadingMore = false
            } else {
                tab.pagination.resetLoadMore()
            }
            tab.pagination.setBaseQueryForMore(
                activeResultSet?.baseQuery,
                parameterValues: activeResultSet?.baseQueryParameterValues
            )
        }
        parent.toolbarState.isResultsCollapsed = false

        if parent.tabManager.selectedTabId == tabId {
            parent.changeManager.clearChangesAndUndoHistory()
            parent.changeManagerMatchesSelectedResult()
        } else {
            parent.dropParkedEdits(ofBackgroundTab: tabId)
        }
    }
}
