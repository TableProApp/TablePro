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
        guard let index = tabManager.selectedTabIndex else { return }
        guard !tabManager.tabs[index].isExecuting else { return }

        let fullQuery = tabManager.tabs[index].query

        let sql: String
        if tabManager.tabs[index].tabType == .table {
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

        Task { @MainActor in
            guard let driver = DatabaseManager.shared.driver(for: connectionId) else { return }

            tabManager.tabs[index].isExecuting = true
            tabManager.tabs[index].explainText = nil
            tabManager.tabs[index].explainExecutionTime = nil
            toolbarState.setExecuting(true)

            do {
                let startTime = Date()
                let result = try await driver.execute(query: explainSQL)
                let duration = Date().timeIntervalSince(startTime)

                let text = result.rows.map { row in
                    row.compactMap { $0 }.joined(separator: "\t")
                }.joined(separator: "\n")

                tabManager.tabs[index].explainText = text
                tabManager.tabs[index].explainExecutionTime = duration
            } catch {
                tabManager.tabs[index].explainText = "Error: \(error.localizedDescription)"
            }

            tabManager.tabs[index].isExecuting = false
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
