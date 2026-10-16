//
//  AgentResultPaneThemeTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProTheme
import Testing

@MainActor
struct AgentResultPaneThemeTests {
    private static let size = CGSize(width: 320, height: 240)
    private static let statePoint = CGPoint(x: 0.05, y: 0.92)

    private static let statement = ProposedStatement(
        id: "1",
        sql: "update users set active = 0 where id = 7",
        toolName: "execute_sql",
        state: .waiting
    )

    /// What the session got back for each state the pane draws in place of the grid.
    nonisolated private static let stateReplies: [String] = [
        #"{"columns":["id"],"rows":[]}"#,
        #"{"columns":[],"rows":[],"rows_affected":2}"#,
        "The table has two rows.",
    ]

    private func rowsView(runs: [AgentQueryRun]) -> some View {
        AgentResultRowsView(runs: runs, artifacts: AgentArtifactCache(), connection: nil)
            .frame(width: Self.size.width, height: Self.size.height)
    }

    private func assertStandsInForTheGrid(_ view: some View) throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .dark) {
            let drawn = try ThemeTestFixture.color(of: view, at: Self.statePoint, colorScheme: .dark)
            #expect(drawn.alphaComponent < 0.01, "default pair drew \(drawn)")

            try ThemeTestFixture.adopt([.gridBackground: ThemeTestFixture.gridHex], appearance: .dark)
            let themed = try ThemeTestFixture.color(of: view, at: Self.statePoint, colorScheme: .dark)
            let grid = try ThemeTestFixture.filled(hex: ThemeTestFixture.gridHex, colorScheme: .dark)
            #expect(ThemeTestFixture.matches(themed, grid), "grid theme drew \(themed), theme \(grid)")

            try ThemeTestFixture.adopt([
                .windowBackdrop: ThemeTestFixture.windowHex,
                .editorBackground: ThemeTestFixture.editorHex,
            ], appearance: .dark)
            let unrelated = try ThemeTestFixture.color(of: view, at: Self.statePoint, colorScheme: .dark)
            #expect(unrelated.alphaComponent < 0.01, "another slot drew \(unrelated)")
        }
    }

    // MARK: - Result states

    @Test("Before the session reads anything the pane stands in for the grid")
    func noResultsYetStandsInForTheGrid() throws {
        try assertStandsInForTheGrid(rowsView(runs: []))
    }

    @Test("A run with nothing to draw stands in for the grid", arguments: AgentResultPaneThemeTests.stateReplies)
    func emptyRunStandsInForTheGrid(reply: String) throws {
        let run = AgentQueryRun(id: "run", sql: "select id from users where false", resultJSON: reply)
        try assertStandsInForTheGrid(rowsView(runs: [run]))
    }

    // MARK: - Proposed statements

    private func row(_ statement: ProposedStatement = AgentResultPaneThemeTests.statement) -> some View {
        AgentProposedStatementRow(statement: statement).frame(width: Self.size.width)
    }

    /// One short line, so the point sampled beside it is the well and never a glyph.
    private static let shortStatement = ProposedStatement(id: "2", sql: "select 1", toolName: "execute_sql", state: .ran)

    @Test("A proposed statement sits on the editor background a theme sets, in the chat well's shape")
    func proposedStatementSitsOnTheEditorBackground() throws {
        try ThemeTestFixture.adopting([.editorBackground: ThemeTestFixture.editorHex], appearance: .dark) {
            let drawn = try ThemeTestFixture.color(of: row(Self.shortStatement), at: CGPoint(x: 0.9, y: 0.2), colorScheme: .dark)
            let editor = try ThemeTestFixture.filled(hex: ThemeTestFixture.editorHex, colorScheme: .dark)
            #expect(ThemeTestFixture.matches(drawn, editor), "drew \(drawn), theme \(editor)")
        }
        try ThemeTestFixture.adopting(.builtIn, appearance: .dark) {
            let drawn = try ThemeTestFixture.color(of: row(Self.shortStatement), at: CGPoint(x: 0.9, y: 0.2), colorScheme: .dark)
            #expect(drawn.alphaComponent < 0.01, "default pair drew \(drawn)")
        }
    }

    /// `ProposedStatement` is equatable, so a row that does not observe the engine is skipped when
    /// only the font moves.
    @Test("A proposed statement on screen follows a Data Grid font change")
    func proposedStatementFollowsTheValueFont() throws {
        let previous = AppSettingsManager.shared.typography
        defer { ThemeEngine.shared.apply(typography: previous) }
        ThemeEngine.shared.apply(typography: TypographySettings(dataGridFontSize: 11))

        let host = NSHostingView(rootView: row())
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let small = host.fittingSize.height

        ThemeEngine.shared.apply(typography: TypographySettings(dataGridFontSize: 22))
        host.layoutSubtreeIfNeeded()
        let large = host.fittingSize.height

        #expect(large > small + 10, "row was \(small)pt at 11pt and \(large)pt at 22pt")
        withExtendedLifetime(window) {}
    }
}
