//
//  EditorAreaControllerTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
import TableProEditorKit
import TableProTextEngine
import Testing

@testable import TablePro

@MainActor
struct EditorAreaControllerTests {
    private final class Flags {
        var historyCollapsed = true
        var resultsCollapsed = false
    }

    private func input(_ content: EditorAreaContent, flags: Flags) -> EditorAreaInput {
        EditorAreaInput(
            content: content,
            history: AnyView(Text("History")),
            isHistoryCollapsed: Binding(get: { flags.historyCollapsed }, set: { flags.historyCollapsed = $0 }),
            historyAutosaveName: "EditorAreaControllerTests.history",
            contentMinimumHeight: CollapsibleSplitController.combinedMinimumThickness
        )
    }

    private func query(_ flags: Flags, text: String = "SELECT 1") -> EditorAreaContent {
        .query(QueryTabInput(
            pane: QueryEditorPaneFixture.input(text: .constant(text)),
            results: AnyView(Text("Results")),
            isResultsCollapsed: Binding(get: { flags.resultsCollapsed }, set: { flags.resultsCollapsed = $0 }),
            resultsAutosaveName: "EditorAreaControllerTests.results"
        ))
    }

    private func editors(in view: NSView) -> [TextView] {
        var found: [TextView] = []
        if let textView = view as? TextView { found.append(textView) }
        for subview in view.subviews { found += editors(in: subview) }
        return found
    }

    @Test("Another kind of tab takes the editor down, and the next query tab gets a new one with its own text")
    func anotherTabTakesTheEditorDown() throws {
        let flags = Flags()
        let area = EditorAreaController(input: input(query(flags), flags: flags))
        defer { area.teardown() }
        let root = area.drawer.view
        root.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        root.layoutSubtreeIfNeeded()
        let editor = try #require(editors(in: root).first)

        area.apply(input(.view(AnyView(Text("Table"))), flags: flags))
        root.layoutSubtreeIfNeeded()
        #expect(editors(in: root).isEmpty)

        area.apply(input(query(flags, text: "SELECT 2"), flags: flags))
        root.layoutSubtreeIfNeeded()
        let next = try #require(editors(in: root).first)
        #expect(next !== editor)
        #expect(next.string == "SELECT 2")
    }

    @Test("A query tab switch keeps the editor and hands it the new tab's text")
    func queryTabSwitchKeepsTheEditor() throws {
        let flags = Flags()
        let area = EditorAreaController(input: input(query(flags), flags: flags))
        defer { area.teardown() }
        let root = area.drawer.view
        root.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        root.layoutSubtreeIfNeeded()
        let editor = try #require(editors(in: root).first)

        area.apply(input(query(flags, text: "SELECT 2"), flags: flags))
        root.layoutSubtreeIfNeeded()
        #expect(editors(in: root).first === editor)
        #expect(editor.string == "SELECT 2")
    }

    @Test("A divider the user collapses is written back, and the owner's own change is not echoed")
    func collapseIsReportedOnlyFromTheUser() {
        let flags = Flags()
        let area = EditorAreaController(input: input(query(flags), flags: flags))
        defer { area.teardown() }
        area.drawer.view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)

        area.drawer.bottomItem.isCollapsed = false
        #expect(flags.historyCollapsed == false)

        flags.historyCollapsed = true
        area.apply(input(query(flags), flags: flags))
        #expect(flags.historyCollapsed)
    }
}
