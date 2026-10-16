//
//  PaneBarThemeTests.swift
//  TableProTests
//
//  A bar over the detail pane keeps the material or fill it always drew until the theme colors the
//  window, then draws nothing, so the pane's theme shows through instead of a system band.
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProTheme
import Testing

@MainActor
struct PaneBarThemeTests {
    private func assertBar(_ view: some View, at point: CGPoint, native: some ShapeStyle) throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .dark) {
            let expected = try ThemeTestFixture.filled(native, colorScheme: .dark)
            try #require(expected.alphaComponent > 0.01, "the native style rendered as nothing")
            let drawn = try ThemeTestFixture.color(of: view, at: point, colorScheme: .dark)
            #expect(ThemeTestFixture.matches(drawn, expected), "default pair drew \(drawn), native \(expected)")

            try ThemeTestFixture.adopt([.windowBackdrop: ThemeTestFixture.windowHex], appearance: .dark)
            let themed = try ThemeTestFixture.color(of: view, at: point, colorScheme: .dark)
            #expect(themed.alphaComponent < 0.01, "window theme drew \(themed)")

            try ThemeTestFixture.adopt([
                .editorBackground: ThemeTestFixture.editorHex,
                .gridBackground: ThemeTestFixture.gridHex,
            ], appearance: .dark)
            let unrelated = try ThemeTestFixture.color(of: view, at: point, colorScheme: .dark)
            #expect(ThemeTestFixture.matches(unrelated, expected), "content slots drew \(unrelated), native \(expected)")
        }
    }

    @Test("The query parameter panel keeps its flat fills until the theme colors the window")
    func parameterPanel() throws {
        let parameters = [QueryParameter(name: "id")]
        let panel = QueryParameterPanelView(parameters: .constant(parameters), onDismiss: {})
            .frame(width: 480)
        try assertBar(panel, at: CGPoint(x: 0.5, y: 0.05), native: Color(nsColor: .controlBackgroundColor))
        try assertBar(panel, at: CGPoint(x: 0.004, y: 0.95), native: Color(nsColor: .windowBackgroundColor))
    }

    @Test("The query editor bar keeps its material until the theme colors the window")
    func queryEditorBar() throws {
        let bar = QueryEditorBar(
            scope: QueryScopeBarModel(
                containers: [],
                selectedName: "shop",
                entityName: String(localized: "Database"),
                isReadOnly: false,
                schemaName: nil
            ),
            commands: QueryCommandAvailability(
                isConnected: true,
                hasQueryText: true,
                isExecuting: false,
                isStoppable: true,
                hasResults: false,
                explainVariants: [],
                shortcutHint: { label, _ in label }
            ),
            isExecuting: false,
            vimMode: nil,
            showsHistoryTip: false,
            onAIAction: { _ in },
            onRun: {},
            onRunAllStatements: {},
            onRunWithoutLimit: {},
            onStop: {},
            onExplain: { _ in },
            onFormat: {},
            onSaveAsFavorite: {},
            onClearQuery: {},
            onClearResults: {},
            onContainerChanged: { _ in }
        )
        .frame(width: 900)
        try assertBar(bar, at: CGPoint(x: 0.5, y: 0.5), native: .bar)
    }

    @Test("The object source bar keeps its material until the theme colors the window")
    func objectSourceBar() throws {
        let view = ObjectSourceTabView(
            connectionId: UUID(),
            databaseType: .mysql,
            objectRef: DatabaseObjectRef(kind: .view, name: "active_orders", database: "shop"),
            onOpenInEditor: { _ in }
        )
        .frame(width: 480, height: 240)
        try assertBar(view, at: CGPoint(x: 0.5, y: 0.02), native: .bar)
    }

    @Test("The loaded source's toolbar keeps its material until the theme colors the window")
    func objectSourceToolbar() throws {
        let view = ObjectSourceView(
            source: "CREATE VIEW active_orders AS SELECT 1",
            databaseType: .mysql,
            exportFileName: "active_orders.sql"
        )
        .frame(width: 480, height: 240)
        try assertBar(view, at: CGPoint(x: 0.5, y: 0.02), native: .bar)
    }
}
