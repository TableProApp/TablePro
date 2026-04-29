//
//  MainContentCoordinator+ClickHouse.swift
//  TablePro
//
//  ClickHouse-specific coordinator methods: progress tracking, EXPLAIN variants.
//

import CodeEditSourceEditor
import Foundation
import TableProPluginKit

extension MainContentCoordinator {
    func installClickHouseProgressHandler() {
        // Progress polling is handled internally by the ClickHouse plugin.
        // This is a no-op stub retained for call-site compatibility.
    }

    func clearClickHouseProgress() {
        if let live = toolbarState.clickHouseProgress {
            toolbarState.lastClickHouseProgress = live
        }
        toolbarState.clickHouseProgress = nil
    }

    /// Run EXPLAIN with a specific variant (e.g. ClickHouse Plan/Pipeline/AST).
    /// Accepts the plugin-kit `ExplainVariant` type for generic dispatch.
    func runVariantExplain(_ variant: ExplainVariant) {
        guard let (tab, _) = tabManager.selectedTabAndIndex,
              !tab.execution.isExecuting else { return }

        let fullQuery = tab.content.query

        let sql: String
        if tab.tabType == .table {
            sql = fullQuery
        } else if let firstCursor = cursorPositions.first,
                  firstCursor.range.length > 0 {
            let nsQuery = fullQuery as NSString
            let clampedRange = NSIntersectionRange(
                firstCursor.range,
                NSRange(location: 0, length: nsQuery.length)
            )
            sql = nsQuery.substring(with: clampedRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            sql = SQLStatementScanner.statementAtCursor(
                in: fullQuery,
                cursorPosition: cursorPositions.first?.range.location ?? 0
            )
        }

        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let statements = SQLStatementScanner.allStatements(in: trimmed)
        guard let stmt = statements.first else { return }

        let explainSQL = "\(variant.sqlPrefix) \(stmt)"
        let tabId = tab.id

        Task {
            guard let driver = DatabaseManager.shared.driver(for: connectionId) else { return }

            if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                tabManager.tabs[idx].execution.isExecuting = true
            }
            toolbarState.setExecuting(true)

            do {
                let startTime = Date()
                let result = try await driver.execute(query: explainSQL)
                let duration = Date().timeIntervalSince(startTime)

                let text = result.rows.map { row in
                    row.compactMap { $0 }.joined(separator: "\t")
                }.joined(separator: "\n")

                if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                    tabManager.tabs[idx].display.explainText = text
                    tabManager.tabs[idx].display.explainExecutionTime = duration

                    if let parser = QueryPlanParserFactory.parser(for: connection.type) {
                        tabManager.tabs[idx].display.explainPlan = parser.parse(rawText: text)
                    } else {
                        tabManager.tabs[idx].display.explainPlan = nil
                    }
                    tabManager.tabs[idx].execution.isExecuting = false
                }
            } catch {
                if let idx = tabManager.tabs.firstIndex(where: { $0.id == tabId }) {
                    tabManager.tabs[idx].display.explainText = "Error: \(error.localizedDescription)"
                    tabManager.tabs[idx].display.explainPlan = nil
                    tabManager.tabs[idx].execution.isExecuting = false
                }
            }

            toolbarState.setExecuting(false)
        }
    }

    /// Legacy bridge: calls runVariantExplain with the matching ExplainVariant.
    func runClickHouseExplain(variant: ClickHouseExplainVariant) {
        let pluginVariant = ExplainVariant(
            id: variant.rawValue.lowercased(),
            label: variant.rawValue,
            sqlPrefix: variant.sqlKeyword
        )
        runVariantExplain(pluginVariant)
    }
}
