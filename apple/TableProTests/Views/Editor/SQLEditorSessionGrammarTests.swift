//
//  SQLEditorSessionGrammarTests.swift
//  TableProTests
//
//  The editor's run controls split with the connection's session grammar, which is only known once the driver has
//  connected, and a reconnect or a `SET` can change it while the editor stays open.
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProEditorKit
import TableProPluginKit
import TableProTestSupport
import TableProTextEngine
import Testing

@MainActor
struct SQLEditorSessionGrammarTests {
    private final class Model {
        var text = "BEGIN\n  x := 1;\n  y := 2;\nEND;\n/\nSELECT 2;"
        var cursorPositions: [CursorPosition] = []
        var ran: [String] = []
    }

    private func runStatementAtCaret(in editor: SQLEditorController, model: Model) -> String? {
        let caret = (model.text as NSString).range(of: "y := 2").location
        editor.textViewController.setCursorPositions([CursorPosition(range: NSRange(location: caret, length: 0))])
        editor.coordinator.runStatementAtCursorAndAdvance()
        return model.ran.popLast()
    }

    @Test("Run Statement takes the whole block once the session reports Oracle mode")
    func runStatementFollowsTheSession() async throws {
        let model = Model()
        let connection = TestFixtures.makeConnection(database: "app", type: .kingbasees)
        let editor = SQLEditorController(input: SQLEditorInput(
            text: Binding(get: { model.text }, set: { model.text = $0 }),
            cursorPositions: Binding(get: { model.cursorPositions }, set: { model.cursorPositions = $0 }),
            databaseType: .kingbasees,
            connectionId: connection.id,
            onRunStatement: { sql, _ in
                model.ran.append(sql)
                return false
            }
        ))
        defer { editor.teardown() }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = editor.textViewController.view
        defer { window.orderOut(nil) }
        let textView = try #require(editor.textViewController.textView)
        try await waitUntil {
            window.contentView?.layoutSubtreeIfNeeded()
            return textView.window != nil
        }

        #expect(runStatementAtCaret(in: editor, model: model) == "y := 2;")

        let driver = ScriptAnsweringDriver(
            connection: connection,
            sessionLexicalState: TestGrammar.kingbaseESOracleSession
        )
        var session = ConnectionSession(connection: connection)
        session.driver = driver
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        try await waitUntil { editor.coordinator.lexicalGrammar == TestGrammar.kingbaseESOracle }

        let block = try #require(runStatementAtCaret(in: editor, model: model))
        #expect(block.hasPrefix("BEGIN\n  x := 1;\n  y := 2;\nEND"))
        #expect(!block.contains("/"))
    }
}
