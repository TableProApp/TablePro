//
//  MainContentCoordinator+ExecuteAll.swift
//  TablePro
//

import AppKit
import Foundation

extension MainContentCoordinator {
    func runAllStatements() {
        guard let index = tabManager.selectedTabIndex else { return }
        guard !tabManager.tabs[index].isExecuting else { return }
        guard tabManager.tabs[index].tabType == .query else { return }

        let fullQuery = tabManager.tabs[index].query
        guard !fullQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let statements = SQLStatementScanner.allStatements(in: fullQuery)
        guard !statements.isEmpty else { return }

        if AppSettingsManager.shared.editor.queryParametersEnabled {
            let combinedSQL = statements.joined(separator: "; ")
            let detectedNames = SQLParameterExtractor.extractParameters(from: combinedSQL)

            if !detectedNames.isEmpty {
                let reconciled = detectAndReconcileParameters(
                    sql: combinedSQL,
                    existing: tabManager.tabs[index].queryParameters
                )
                tabManager.tabs[index].queryParameters = reconciled

                if !tabManager.tabs[index].isParameterPanelVisible {
                    tabManager.tabs[index].isParameterPanelVisible = true
                    return
                }

                dispatchParameterizedStatements(statements, parameters: reconciled, tabIndex: index)
                return
            }
        }

        dispatchStatements(statements, tabIndex: index)
    }

    internal func dispatchStatements(_ statements: [String], tabIndex index: Int) {
        let level = safeModeLevel

        if level == .readOnly {
            let writeStatements = statements.filter { isWriteQuery($0) }
            if !writeStatements.isEmpty {
                tabManager.tabs[index].errorMessage =
                    String(localized: "Cannot execute write queries: connection is read-only")
                return
            }
        }

        if level == .silent {
            if statements.count == 1 {
                Task {
                    let window = NSApp.keyWindow
                    guard await confirmDangerousQueryIfNeeded(statements[0], window: window) else { return }
                    executeQueryInternal(statements[0])
                }
            } else {
                Task {
                    let window = NSApp.keyWindow
                    let dangerousStatements = statements.filter { isDangerousQuery($0) }
                    if !dangerousStatements.isEmpty {
                        guard await confirmDangerousQueries(dangerousStatements, window: window) else { return }
                    }
                    executeMultipleStatements(statements)
                }
            }
        } else if level.requiresConfirmation {
            guard !isShowingSafeModePrompt else { return }
            isShowingSafeModePrompt = true
            Task {
                defer { isShowingSafeModePrompt = false }
                let window = NSApp.keyWindow
                let combinedSQL = statements.joined(separator: "\n")
                let hasWrite = statements.contains { isWriteQuery($0) }
                let permission = await SafeModeGuard.checkPermission(
                    level: level,
                    isWriteOperation: hasWrite,
                    sql: combinedSQL,
                    operationDescription: String(localized: "Execute Query"),
                    window: window,
                    databaseType: connection.type
                )
                switch permission {
                case .allowed:
                    if statements.count == 1 {
                        executeQueryInternal(statements[0])
                    } else {
                        executeMultipleStatements(statements)
                    }
                case .blocked(let reason):
                    if index < tabManager.tabs.count {
                        tabManager.tabs[index].errorMessage = reason
                    }
                }
            }
        } else {
            if statements.count == 1 {
                executeQueryInternal(statements[0])
            } else {
                executeMultipleStatements(statements)
            }
        }
    }

    internal func dispatchParameterizedStatements(
        _ statements: [String],
        parameters: [QueryParameter],
        tabIndex index: Int
    ) {
        let level = safeModeLevel

        if level == .readOnly {
            let writeStatements = statements.filter { isWriteQuery($0) }
            if !writeStatements.isEmpty {
                tabManager.tabs[index].errorMessage =
                    String(localized: "Cannot execute write queries: connection is read-only")
                return
            }
        }

        let tabId = tabManager.tabs[index].id

        if level == .silent {
            Task {
                let window = NSApp.keyWindow
                if statements.count == 1 {
                    guard await confirmDangerousQueryIfNeeded(statements[0], window: window) else { return }
                } else {
                    let dangerousStatements = statements.filter { isDangerousQuery($0) }
                    if !dangerousStatements.isEmpty {
                        guard await confirmDangerousQueries(dangerousStatements, window: window) else { return }
                    }
                }
                executeParameterizedAfterSafeMode(statements, parameters: parameters)
            }
        } else if level.requiresConfirmation {
            guard !isShowingSafeModePrompt else { return }
            isShowingSafeModePrompt = true
            Task {
                defer { isShowingSafeModePrompt = false }
                let window = NSApp.keyWindow
                let combinedSQL = statements.joined(separator: "\n")
                let hasWrite = statements.contains { isWriteQuery($0) }
                let permission = await SafeModeGuard.checkPermission(
                    level: level,
                    isWriteOperation: hasWrite,
                    sql: combinedSQL,
                    operationDescription: String(localized: "Execute Query"),
                    window: window,
                    databaseType: connection.type
                )
                switch permission {
                case .allowed:
                    executeParameterizedAfterSafeMode(statements, parameters: parameters)
                case .blocked(let reason):
                    if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                        tabManager.tabs[idx].errorMessage = reason
                    }
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
