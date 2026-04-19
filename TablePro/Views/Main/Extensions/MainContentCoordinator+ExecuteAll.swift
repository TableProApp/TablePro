//
//  MainContentCoordinator+ExecuteAll.swift
//  TablePro
//
//  Execute All Statements and safe mode dispatch logic shared
//  between runQuery() and runAllStatements().
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
                Task { @MainActor in
                    let window = NSApp.keyWindow
                    guard await confirmDangerousQueryIfNeeded(statements[0], window: window) else { return }
                    executeQueryInternal(statements[0])
                }
            } else {
                Task { @MainActor in
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
            Task { @MainActor in
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
}
