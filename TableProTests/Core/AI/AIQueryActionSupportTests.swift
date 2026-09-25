//
//  AIQueryActionSupportTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct AIQueryActionAvailabilityTests {
    private func availability(
        aiEnabled: Bool = true,
        provider: Bool = true,
        policy: AIConnectionPolicy? = .alwaysAllow,
        queryTab: Bool = true,
        connected: Bool = true,
        statement: Bool = true
    ) -> AIQueryActionAvailability {
        AIQueryActionAvailability(
            aiEnabled: aiEnabled,
            hasActiveProvider: provider,
            connectionPolicy: policy,
            isQueryTab: queryTab,
            isConnected: connected,
            hasStatement: statement
        )
    }

    @Test("Everything in place: visible and enabled")
    func enabled() {
        let value = availability()
        #expect(value.isVisible)
        #expect(value.isEnabled)
        #expect(value.blockedReason == nil)
    }

    @Test("AI off, a Never connection, or a table tab hides the actions", arguments: [
        (false, AIConnectionPolicy.alwaysAllow, true),
        (true, AIConnectionPolicy.never, true),
        (true, AIConnectionPolicy.alwaysAllow, false)
    ])
    func hidden(aiEnabled: Bool, policy: AIConnectionPolicy, queryTab: Bool) {
        let value = availability(aiEnabled: aiEnabled, policy: policy, queryTab: queryTab)
        #expect(!value.isVisible)
        #expect(!value.isEnabled)
    }

    @Test("Ask Each Time stays available, because the send itself asks")
    func askEachTime() {
        #expect(availability(policy: .askEachTime).isEnabled)
    }

    @Test("No provider, no statement or no connection dims with a reason")
    func dimmedWithReason() {
        for value in [availability(provider: false), availability(statement: false), availability(connected: false)] {
            #expect(value.isVisible)
            #expect(!value.isEnabled)
            #expect(value.blockedReason != nil)
            #expect(value.hint(base: "Review with AI").hasPrefix("Review with AI\n"))
        }
    }
}

struct AIQueryTargetTests {
    @Test("A word the right-click selected sends the statement around it")
    func contextClickWordUsesStatement() {
        let word = NSRange(location: 14, length: 6)
        #expect(AIQueryTarget.contextMenu(selectedRange: word, contextClickWord: word) == .statement(containing: 14))
    }

    @Test("A selection the user made, or none recorded, follows the Run rule")
    func userSelectionFollowsRun() {
        let selection = NSRange(location: 0, length: 30)
        #expect(AIQueryTarget.contextMenu(selectedRange: selection, contextClickWord: nil) == .selectionOrStatementAtCursor)
        #expect(AIQueryTarget.contextMenu(selectedRange: selection, contextClickWord: NSRange(location: 3, length: 4))
            == .selectionOrStatementAtCursor)
    }
}

struct WalkthroughApplyPlanTests {
    private let tabId = UUID()
    private let text = "SELECT 1;\nSELECT * FROM t WHERE a = 1;\nSELECT 3;"

    private var statementRange: NSRange {
        (text as NSString).range(of: "SELECT * FROM t WHERE a = 1")
    }

    @Test("An unchanged anchored statement is replaced in place and nothing else moves")
    func replacesAnchoredRange() {
        let plan = WalkthroughApplyPlan.resolve(
            beforeSQL: "SELECT * FROM t WHERE a = 1",
            source: QueryEditorAnchor(tabId: tabId, range: statementRange),
            tabText: text
        )
        #expect(plan == .replace(tabId: tabId, range: statementRange))
    }

    @Test("A statement that moved but still appears once is found again")
    func findsMovedStatement() {
        let moved = "-- note\n" + text
        let plan = WalkthroughApplyPlan.resolve(
            beforeSQL: "SELECT * FROM t WHERE a = 1",
            source: QueryEditorAnchor(tabId: tabId, range: statementRange),
            tabText: moved
        )
        #expect(plan == .replace(tabId: tabId, range: (moved as NSString).range(of: "SELECT * FROM t WHERE a = 1")))
    }

    @Test("An edited, duplicated or vanished statement, or a closed tab, goes to a new query instead")
    func fallsBackToNewQuery() {
        let anchor = QueryEditorAnchor(tabId: tabId, range: statementRange)
        #expect(WalkthroughApplyPlan.resolve(beforeSQL: "SELECT * FROM t WHERE a = 2", source: anchor, tabText: text)
            == .insertAsNewQuery)
        #expect(WalkthroughApplyPlan.resolve(beforeSQL: "SELECT 1", source: QueryEditorAnchor(tabId: tabId), tabText: "SELECT 1; SELECT 1;")
            == .insertAsNewQuery)
        #expect(WalkthroughApplyPlan.resolve(beforeSQL: "SELECT 1", source: anchor, tabText: nil) == .insertAsNewQuery)
        #expect(WalkthroughApplyPlan.resolve(beforeSQL: "SELECT 1", source: nil, tabText: text) == .insertAsNewQuery)
    }

    @Test("A range past the end of the text is never used")
    func outOfBoundsRange() {
        let anchor = QueryEditorAnchor(tabId: tabId, range: NSRange(location: 500, length: 8))
        #expect(WalkthroughApplyPlan.resolve(beforeSQL: "SELECT 3", source: anchor, tabText: text)
            == .replace(tabId: tabId, range: (text as NSString).range(of: "SELECT 3")))
    }
}

struct QueryContextAttachmentTests {
    private func attachment() -> QueryContextAttachment {
        QueryContextAttachment(connectionId: UUID(), database: "shop", schema: "public", statement: "SELECT * FROM orders")
    }

    @Test("It round-trips through ContextItem coding, resolved state included")
    func codableRoundTrip() throws {
        let resolved = attachment().resolved(with: QueryContextSnapshot(engineName: "PostgreSQL", notFound: ["ghost"]))
        let data = try JSONEncoder().encode(ContextItem.queryContext(resolved))
        let decoded = try JSONDecoder().decode(ContextItem.self, from: data)
        #expect(decoded == .queryContext(resolved))
        #expect(resolved.isResolved)
        #expect(resolved.missingNames == ["ghost"])
    }

    @Test("The chip names the tables sent, and says so before they are read")
    func chipLabel() {
        let pending = attachment()
        #expect(!pending.isResolved)
        #expect(pending.chipLabel == String(localized: "Table structure"))

        let tables = ["a", "b", "c", "d"].map {
            QueryContextTable(name: $0, schema: nil, kind: .table, content: .unavailable(reason: "x"))
        }
        let resolved = pending.resolved(with: QueryContextSnapshot(engineName: "MySQL", tables: tables))
        #expect(resolved.chipLabel.hasPrefix("a, b, c"))
        #expect(resolved.helpText.contains("a, b, c, d"))
        #expect(ContextItem.queryContext(resolved).helpText == resolved.helpText)
    }

    @Test("A walkthrough keeps its source anchor, and an old one without it still decodes")
    func walkthroughSource() throws {
        let anchor = QueryEditorAnchor(tabId: UUID(), range: NSRange(location: 4, length: 9))
        let block = SqlWalkthroughBlock(
            beforeSQL: "SELECT 1",
            envelope: SqlWalkthroughEnvelope(afterSQL: "SELECT 2", steps: []),
            source: anchor
        )
        let decoded = try JSONDecoder().decode(SqlWalkthroughBlock.self, from: JSONEncoder().encode(block))
        #expect(decoded.source == anchor)
        #expect(decoded.source?.range == NSRange(location: 4, length: 9))

        let legacy = #"{"beforeSQL":"SELECT 1","envelope":{"afterSQL":null,"steps":[]}}"#
        let old = try JSONDecoder().decode(SqlWalkthroughBlock.self, from: Data(legacy.utf8))
        #expect(old.source == nil)
    }
}

struct AIQueryActionShortcutTests {
    @Test("Every AI query shortcut is an editor-context command, Review on Option-Shift-Command-L")
    func shortcuts() {
        for shortcut in [ShortcutAction.aiReviewQuery, .aiExplainQuery, .aiOptimizeQuery] {
            #expect(shortcut.context == .editor)
            #expect(shortcut.category == .editor)
        }
        #expect(KeyboardSettings.defaultShortcuts[.aiReviewQuery] == .character("l", command: true, shift: true, option: true))
    }

    @Test("The Review default collides with no other default")
    func noDefaultCollision() {
        guard let review = KeyboardSettings.defaultShortcuts[.aiReviewQuery] else {
            Issue.record("Review with AI has no default")
            return
        }
        let others = KeyboardSettings.defaultShortcuts.filter { $0.key != .aiReviewQuery && $0.value == review }
        #expect(others.isEmpty)
    }
}
