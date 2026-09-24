//
//  MainContentCoordinator+AIQueryActions.swift
//  TablePro
//

import Foundation
import TableProEditorKit
import TableProPluginKit
import TableProSQLGrammar

extension MainContentCoordinator {
    static let aiExplainPlanLimit = 20_000

    var aiQueryActionAvailability: AIQueryActionAvailability {
        aiQueryActionAvailability(for: tabManager.selectedTab)
    }

    func aiQueryActionAvailability(for tab: QueryTab?) -> AIQueryActionAvailability {
        let settings = AppSettingsManager.shared.ai
        return AIQueryActionAvailability(
            aiEnabled: settings.enabled,
            hasActiveProvider: settings.hasActiveProvider,
            connectionPolicy: connection.aiPolicy ?? settings.defaultConnectionPolicy,
            isQueryTab: tab?.tabType == .query,
            isConnected: MainWindowToolbar.hasLiveSession(toolbarState.connectionState),
            hasStatement: tab?.hasQueryText ?? false
        )
    }

    var assistantEditorSnapshot: AssistantEditorSnapshot {
        guard let tab = tabManager.selectedTab else { return .empty }
        guard tab.tabType == .query else { return AssistantEditorSnapshot(currentQuery: tab.content.query, target: nil) }
        return AssistantEditorSnapshot(
            currentQuery: tab.content.query,
            target: AssistantEditorTarget(
                tabId: tab.id,
                scope: scope(for: tab),
                errorMessage: tab.display.activeResultSet?.errorMessage ?? tab.execution.errorMessage,
                errorQuery: tab.execution.errorQuery
            )
        )
    }

    func runAIQueryAction(_ action: AIQueryAction, target: AIQueryTarget = .selectionOrStatementAtCursor) {
        guard aiQueryActionAvailability.isEnabled,
              let tab = tabManager.selectedTab,
              let request = aiQueryRequest(for: action, in: tab, target: target) else { return }
        showAssistant()
        aiViewModel?.runQueryAction(request)
    }

    func fixErrorWithAI(query: String, error: String) {
        guard let tab = tabManager.selectedTab else { return }
        let source = QueryEditorAnchor(tabId: tab.id, range: WalkthroughApplyPlan.uniqueRange(of: query, in: tab.content.query))
        let request = AIQueryRequest(
            action: .fixError,
            statement: query,
            editorText: tab.content.query,
            scope: scope(for: tab),
            databaseType: connection.type,
            source: source,
            errorMessage: error
        )
        showAssistant()
        aiViewModel?.runQueryAction(request)
    }

    func aiQueryRequest(
        for action: AIQueryAction,
        in tab: QueryTab,
        target: AIQueryTarget = .selectionOrStatementAtCursor
    ) -> AIQueryRequest? {
        guard tab.tabType == .query else { return nil }
        let resolved = editorText(for: target, in: tab.content.query)
        guard let trimmed = Self.trimmed(resolved.sql, offset: resolved.offset) else { return nil }
        let range = NSRange(location: trimmed.offset, length: (trimmed.sql as NSString).length)
        return AIQueryRequest(
            action: action,
            statement: trimmed.sql,
            editorText: tab.content.query,
            scope: scope(for: tab),
            databaseType: connection.type,
            source: QueryEditorAnchor(tabId: tab.id, range: range),
            explainPlan: explainPlan(in: tab, covering: range)
        )
    }

    func editorText(for target: AIQueryTarget, in fullQuery: String) -> (sql: String, offset: Int) {
        switch target {
        case .selectionOrStatementAtCursor:
            return selectionOrStatementAtCursor(in: fullQuery)
        case .statement(let offset):
            let statement = QueryStatementScanner.locatedStatementAtCursor(
                in: fullQuery,
                cursorPosition: min(max(0, offset), (fullQuery as NSString).length),
                model: statementModel,
                grammar: lexicalGrammar
            )
            return (statement.sql, statement.offset)
        }
    }

    func selectionOrStatementAtCursor(in fullQuery: String) -> (sql: String, offset: Int) {
        if let firstCursor = cursorPositions.first, firstCursor.range.length > 0 {
            let nsQuery = fullQuery as NSString
            let clampedRange = NSIntersectionRange(firstCursor.range, NSRange(location: 0, length: nsQuery.length))
            return (nsQuery.substring(with: clampedRange), clampedRange.location)
        }
        let statement = QueryStatementScanner.locatedStatementAtCursor(
            in: fullQuery,
            cursorPosition: cursorPositions.first?.range.location ?? 0,
            model: statementModel,
            grammar: lexicalGrammar
        )
        return (statement.sql, statement.offset)
    }

    func applyAISuggestion(_ afterSQL: String, replacing beforeSQL: String, source: QueryEditorAnchor?) {
        let owner = source.flatMap { Self.coordinator(owningTab: $0.tabId) }
        let tabText = source.flatMap { anchor in
            owner?.tabManager.tabs.first { $0.id == anchor.tabId }?.content.query
        }
        switch WalkthroughApplyPlan.resolve(beforeSQL: beforeSQL, source: source, tabText: tabText) {
        case .replace(let tabId, let range):
            guard let owner else { return }
            owner.tabManager.mutate(tabId: tabId) { tab in
                let text = tab.content.query as NSString
                guard NSMaxRange(range) <= text.length else { return }
                tab.content.query = text.replacingCharacters(in: range, with: afterSQL)
                tab.hasUserInteraction = true
            }
        case .insertAsNewQuery:
            insertQueryFromAI(afterSQL)
        }
    }

    private func explainPlan(in tab: QueryTab, covering range: NSRange) -> String? {
        let text = tab.content.query as NSString
        let plan = tab.display.resultSets.reversed().first { resultSet in
            guard resultSet.explainRawText != nil, let anchor = resultSet.statementAnchor else { return false }
            guard NSMaxRange(anchor.range) <= text.length,
                  NSIntersectionRange(anchor.range, range) == anchor.range else { return false }
            return text.substring(with: anchor.range).hasPrefix(anchor.preview)
        }?.explainRawText
        guard let plan, !plan.isEmpty else { return nil }
        let nsPlan = plan as NSString
        guard nsPlan.length > Self.aiExplainPlanLimit else { return plan }
        return nsPlan.substring(to: Self.aiExplainPlanLimit) + "\n… truncated"
    }

    private static func coordinator(owningTab tabId: UUID) -> MainContentCoordinator? {
        activeCoordinators.values.first { coordinator in
            coordinator.tabManager.tabs.contains { $0.id == tabId }
        }
    }

    static func trimmed(_ sql: String, offset: Int) -> (sql: String, offset: Int)? {
        let text = sql as NSString
        var start = 0
        var end = text.length
        while start < end, let scalar = UnicodeScalar(text.character(at: start)),
              CharacterSet.whitespacesAndNewlines.contains(scalar) {
            start += 1
        }
        while end > start, let scalar = UnicodeScalar(text.character(at: end - 1)),
              CharacterSet.whitespacesAndNewlines.contains(scalar) {
            end -= 1
        }
        guard end > start else { return nil }
        return (text.substring(with: NSRange(location: start, length: end - start)), offset + start)
    }
}
