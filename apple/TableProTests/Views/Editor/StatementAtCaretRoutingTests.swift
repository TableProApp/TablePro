import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProEditorKit
import TableProPluginKit
import TableProSQLGrammar
import TableProTestSupport
import TableProTextEngine
import Testing

// Cmd-Return, Explain and the AI actions read the caret's statement from the mounted editor's index, and only when that
// editor holds the same text split the same way.
@MainActor
struct StatementAtCaretRoutingTests {
    private final class Model {
        var text: String
        var cursorPositions: [CursorPosition] = []

        init(text: String) {
            self.text = text
        }
    }

    private struct Mounted {
        let editor: SQLEditorController
        let window: NSWindow
        let model: Model

        func unmount() {
            window.orderOut(nil)
            editor.teardown()
        }
    }

    private let router = EditorEventRouter.shared

    private func mount(_ text: String, type: DatabaseType = .mysql, tabID: UUID, connectionId: UUID) async throws -> Mounted {
        let model = Model(text: text)
        let editor = SQLEditorController(input: SQLEditorInput(
            text: Binding(get: { model.text }, set: { model.text = $0 }),
            cursorPositions: Binding(get: { model.cursorPositions }, set: { model.cursorPositions = $0 }),
            databaseType: type,
            connectionId: connectionId,
            tabID: tabID
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = editor.textViewController.view
        let mounted = Mounted(editor: editor, window: window, model: model)
        let grammar = SQLLexicalResolver.executionGrammar(for: type, connectionId: connectionId)
        let statementModel = QueryStatementModel.forDatabaseType(type)
        try await waitUntil {
            window.contentView?.layoutSubtreeIfNeeded()
            return self.router.statement(
                at: 0, in: text, forTab: tabID, connectionId: connectionId, model: statementModel, grammar: grammar
            ) != nil
        }
        return mounted
    }

    private func expectFreshScan(
        _ statement: SQLStatementScanner.LocatedStatement?,
        at caret: Int,
        in text: String,
        model: QueryStatementModel,
        grammar: SQLLexicalGrammar,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let fresh = QueryStatementScanner.locatedStatementAtCursor(
            in: text, cursorPosition: caret, model: model, grammar: grammar
        )
        #expect(statement?.range == fresh.range, "caret \(caret)", sourceLocation: sourceLocation)
        #expect(statement?.sql == fresh.sql, "caret \(caret)", sourceLocation: sourceLocation)
        #expect(statement?.hasContent == fresh.hasContent, "caret \(caret)", sourceLocation: sourceLocation)
    }

    @Test
    func aMountedLongScriptAnswersWhatAFreshScanAnswers() async throws {
        let tabID = UUID()
        let connectionId = UUID()
        let script = (0..<10_000).map { "SELECT \($0) FROM t WHERE c = 'x;y';" }.joined(separator: "\n")
        let mounted = try await mount(script, tabID: tabID, connectionId: connectionId)
        defer { mounted.unmount() }
        let grammar = SQLLexicalResolver.executionGrammar(for: .mysql, connectionId: connectionId)
        let length = (script as NSString).length
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D

        for _ in 0..<50 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let caret = Int((seed >> 33) % UInt64(length + 1))
            let statement = router.statement(
                at: caret, in: script, forTab: tabID, connectionId: connectionId, model: .sql, grammar: grammar
            )
            #expect(statement != nil)
            expectFreshScan(statement, at: caret, in: script, model: .sql, grammar: grammar)
        }
    }

    @Test
    func aTabWithNoMountedEditorGetsNoAnswer() {
        let statement = router.statement(
            at: 0, in: "SELECT 1;", forTab: UUID(), connectionId: UUID(), model: .sql, grammar: .ansi
        )
        #expect(statement == nil)
    }

    @Test
    func textOfTheSameLengthThatDiffersGetsNoAnswer() async throws {
        let tabID = UUID()
        let connectionId = UUID()
        let mounted = try await mount("SELECT 1;\nSELECT 2;", tabID: tabID, connectionId: connectionId)
        defer { mounted.unmount() }
        let grammar = SQLLexicalResolver.executionGrammar(for: .mysql, connectionId: connectionId)

        let statement = router.statement(
            at: 12, in: "SELECT 3;\nSELECT 4;", forTab: tabID, connectionId: connectionId, model: .sql, grammar: grammar
        )

        #expect(statement == nil)
    }

    @Test
    func anotherGrammarGetsNoAnswer() async throws {
        let tabID = UUID()
        let connectionId = UUID()
        let text = "SELECT 1 # note ; still the note\nSELECT 2;"
        let mounted = try await mount(text, tabID: tabID, connectionId: connectionId)
        defer { mounted.unmount() }
        let grammar = SQLLexicalResolver.executionGrammar(for: .mysql, connectionId: connectionId)
        try #require(grammar != .ansi)

        let statement = router.statement(at: 20, in: text, forTab: tabID, connectionId: connectionId, model: .sql, grammar: .ansi)

        #expect(statement == nil)
    }

    @Test
    func withTwoEditorsOnOneTabTheOneHoldingTheTextAnswers() async throws {
        let tabID = UUID()
        let connectionId = UUID()
        let first = "SELECT 1;\nSELECT 2;"
        let second = "UPDATE t SET a = 1;\nDELETE FROM t WHERE a = 2;"
        let mountedFirst = try await mount(first, tabID: tabID, connectionId: connectionId)
        defer { mountedFirst.unmount() }
        let mountedSecond = try await mount(second, tabID: tabID, connectionId: connectionId)
        defer { mountedSecond.unmount() }
        let grammar = SQLLexicalResolver.executionGrammar(for: .mysql, connectionId: connectionId)

        for (text, caret) in [(second, 30), (first, 12), (second, 2)] {
            let statement = router.statement(
                at: caret, in: text, forTab: tabID, connectionId: connectionId, model: .sql, grammar: grammar
            )
            #expect(statement != nil)
            expectFreshScan(statement, at: caret, in: text, model: .sql, grammar: grammar)
        }
    }

    @Test(arguments: [
        (DatabaseType.redis, "SET a 1\nGET a\nHSET h f \"v;w\"\n"),
        (DatabaseType.mongodb, "db.a.find({ x: \"1;2\" })\ndb.b.insertOne({ y: 2 });\ndb.c.countDocuments()\n"),
    ])
    func redisAndJavaScriptTabsAnswerAsTheirSplitterDoes(type: DatabaseType, text: String) async throws {
        let tabID = UUID()
        let connectionId = UUID()
        let mounted = try await mount(text, type: type, tabID: tabID, connectionId: connectionId)
        defer { mounted.unmount() }
        let grammar = SQLLexicalResolver.executionGrammar(for: type, connectionId: connectionId)
        let model = QueryStatementModel.forDatabaseType(type)

        for caret in stride(from: 0, through: (text as NSString).length, by: 7) {
            let statement = router.statement(
                at: caret, in: text, forTab: tabID, connectionId: connectionId, model: model, grammar: grammar
            )
            #expect(statement != nil)
            expectFreshScan(statement, at: caret, in: text, model: model, grammar: grammar)
        }
    }

    @Test
    func runAtTheCaretUsesTheTabTextWhenTheEditorHoldsOther() async throws {
        let fixture = CoordinatorFixture()
        let tab = fixture.addTab(QueryTab(title: "Query 1", query: "SELECT 3;\nSELECT 4;", tabType: .query))
        let mounted = try await mount(
            "SELECT 1;\nSELECT 2;", type: fixture.connection.type, tabID: tab.id, connectionId: fixture.connection.id
        )
        defer { mounted.unmount() }
        fixture.coordinator.cursorPositions = [CursorPosition(range: NSRange(location: 12, length: 0))]

        let target = fixture.coordinator.selectionOrStatementAtCursor(in: tab.content.query)
        let fresh = QueryStatementScanner.locatedStatementAtCursor(
            in: tab.content.query,
            cursorPosition: 12,
            model: fixture.coordinator.statementModel,
            grammar: fixture.coordinator.lexicalGrammar
        )

        #expect(target.sql == fresh.sql)
        #expect(target.offset == fresh.offset)
        #expect(target.sql.contains("SELECT 4;"))
    }

    @Test
    func runAtTheCaretReadsTheMountedEditorHoldingTheTabText() async throws {
        let fixture = CoordinatorFixture()
        let query = (0..<2_000).map { "SELECT \($0);" }.joined(separator: "\n")
        let tab = fixture.addTab(QueryTab(title: "Query 1", query: query, tabType: .query))
        let mounted = try await mount(query, type: fixture.connection.type, tabID: tab.id, connectionId: fixture.connection.id)
        defer { mounted.unmount() }
        let caret = (query as NSString).range(of: "SELECT 1500;").location + 3
        fixture.coordinator.cursorPositions = [CursorPosition(range: NSRange(location: caret, length: 0))]

        let indexed = router.statement(
            at: caret,
            in: query,
            forTab: tab.id,
            connectionId: fixture.connection.id,
            model: fixture.coordinator.statementModel,
            grammar: fixture.coordinator.lexicalGrammar
        )
        #expect(indexed != nil)

        let target = fixture.coordinator.selectionOrStatementAtCursor(in: query)
        let fresh = QueryStatementScanner.locatedStatementAtCursor(
            in: query,
            cursorPosition: caret,
            model: fixture.coordinator.statementModel,
            grammar: fixture.coordinator.lexicalGrammar
        )

        #expect(target.sql == fresh.sql)
        #expect(target.offset == fresh.offset)
    }
}
