//
//  QueryExecutionCoordinator.swift
//  TablePro
//

import AppKit
import Foundation

@MainActor @Observable
final class QueryExecutionCoordinator {
    @ObservationIgnored unowned let parent: MainContentCoordinator

    init(parent: MainContentCoordinator) {
        self.parent = parent
    }

    // MARK: - Run All Statements

    func runAllStatements() {
        guard let (tab, index) = parent.tabManager.selectedTabAndIndex,
              !tab.execution.isExecuting,
              tab.tabType == .query else { return }

        let fullQuery = tab.content.query
        guard !fullQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let statements = SQLStatementScanner.allStatements(in: fullQuery)
        guard !statements.isEmpty else { return }

        if AppSettingsManager.shared.editor.queryParametersEnabled {
            let combinedSQL = statements.joined(separator: "; ")
            let detectedNames = SQLParameterExtractor.extractParameters(from: combinedSQL)

            if !detectedNames.isEmpty {
                let reconciled = detectAndReconcileParameters(
                    sql: combinedSQL,
                    existing: parent.tabManager.tabs[index].content.queryParameters
                )
                parent.tabManager.mutate(at: index) { $0.content.queryParameters = reconciled }

                if !parent.tabManager.tabs[index].content.isParameterPanelVisible {
                    parent.tabManager.mutate(at: index) { $0.content.isParameterPanelVisible = true }
                    return
                }

                dispatchParameterizedStatements(statements, parameters: reconciled, tabIndex: index)
                return
            }
        }

        dispatchStatements(statements, tabIndex: index)
    }

    func dispatchStatements(_ statements: [String], tabIndex index: Int) {
        let level = parent.safeModeLevel

        if level == .readOnly {
            let writeStatements = statements.filter { parent.isWriteQuery($0) }
            if !writeStatements.isEmpty {
                parent.tabManager.mutate(at: index) {
                    $0.execution.errorMessage =
                        String(localized: "Cannot execute write queries: connection is read only")
                }
                return
            }
        }

        if level == .silent {
            if statements.count == 1 {
                Task { [parent] in
                    let window = NSApp.keyWindow
                    guard await parent.confirmDangerousQueryIfNeeded(statements[0], window: window) else { return }
                    parent.executeQueryInternal(statements[0])
                }
            } else {
                Task { [parent] in
                    let window = NSApp.keyWindow
                    let dangerousStatements = statements.filter { parent.isDangerousQuery($0) }
                    if !dangerousStatements.isEmpty {
                        guard await parent.confirmDangerousQueries(dangerousStatements, window: window) else { return }
                    }
                    executeMultipleStatements(statements)
                }
            }
        } else if level.requiresConfirmation {
            guard !parent.isShowingSafeModePrompt else { return }
            parent.isShowingSafeModePrompt = true
            Task { [parent] in
                defer { parent.isShowingSafeModePrompt = false }
                let window = NSApp.keyWindow
                let combinedSQL = statements.joined(separator: "\n")
                let hasWrite = statements.contains { parent.isWriteQuery($0) }
                let permission = await SafeModeGuard.checkPermission(
                    level: level,
                    isWriteOperation: hasWrite,
                    sql: combinedSQL,
                    operationDescription: String(localized: "Execute Query"),
                    window: window,
                    databaseType: parent.connection.type
                )
                switch permission {
                case .allowed:
                    if statements.count == 1 {
                        parent.executeQueryInternal(statements[0])
                    } else {
                        executeMultipleStatements(statements)
                    }
                case .blocked(let reason):
                    parent.tabManager.mutate(at: index) { $0.execution.errorMessage = reason }
                }
            }
        } else {
            if statements.count == 1 {
                parent.executeQueryInternal(statements[0])
            } else {
                executeMultipleStatements(statements)
            }
        }
    }

    func dispatchParameterizedStatements(
        _ statements: [String],
        parameters: [QueryParameter],
        tabIndex index: Int
    ) {
        let level = parent.safeModeLevel

        if level == .readOnly {
            let writeStatements = statements.filter { parent.isWriteQuery($0) }
            if !writeStatements.isEmpty {
                parent.tabManager.mutate(at: index) {
                    $0.execution.errorMessage =
                        String(localized: "Cannot execute write queries: connection is read only")
                }
                return
            }
        }

        let tabId = parent.tabManager.tabs[index].id

        if level == .silent {
            Task { [parent] in
                let window = NSApp.keyWindow
                if statements.count == 1 {
                    guard await parent.confirmDangerousQueryIfNeeded(statements[0], window: window) else { return }
                } else {
                    let dangerousStatements = statements.filter { parent.isDangerousQuery($0) }
                    if !dangerousStatements.isEmpty {
                        guard await parent.confirmDangerousQueries(dangerousStatements, window: window) else { return }
                    }
                }
                executeParameterizedAfterSafeMode(statements, parameters: parameters)
            }
        } else if level.requiresConfirmation {
            guard !parent.isShowingSafeModePrompt else { return }
            parent.isShowingSafeModePrompt = true
            Task { [parent] in
                defer { parent.isShowingSafeModePrompt = false }
                let window = NSApp.keyWindow
                let combinedSQL = statements.joined(separator: "\n")
                let hasWrite = statements.contains { parent.isWriteQuery($0) }
                let permission = await SafeModeGuard.checkPermission(
                    level: level,
                    isWriteOperation: hasWrite,
                    sql: combinedSQL,
                    operationDescription: String(localized: "Execute Query"),
                    window: window,
                    databaseType: parent.connection.type
                )
                switch permission {
                case .allowed:
                    executeParameterizedAfterSafeMode(statements, parameters: parameters)
                case .blocked(let reason):
                    parent.tabManager.mutate(tabId: tabId) { $0.execution.errorMessage = reason }
                }
            }
        } else {
            executeParameterizedAfterSafeMode(statements, parameters: parameters)
        }
    }

    private func executeParameterizedAfterSafeMode(
        _ statements: [String],
        parameters: [QueryParameter]
    ) {
        if statements.count == 1 {
            executeQueryWithParameters(statements[0], parameters: parameters)
        } else {
            executeMultipleStatementsWithParameters(statements, parameters: parameters)
        }
    }
}
