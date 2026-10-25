import AppKit
import SwiftUI
@testable import TablePro
import Testing

// A list's content-background material never takes the window color, so inside the glass
// inspector it drew a second, untinted surface behind the fields.
@MainActor
struct SplitItemGlassBackgroundTests {
    private static let size = NSSize(width: 280, height: 360)

    private static func contentBackgrounds(in view: NSView?) -> [NSVisualEffectView] {
        guard let view else { return [] }
        let own = (view as? NSVisualEffectView).map { $0.material == .contentBackground ? [$0] : [] } ?? []
        return own + view.subviews.flatMap { contentBackgrounds(in: $0) }
    }

    private func drawsListMaterial(_ view: some View) -> Bool {
        let window = ThemeTestFixture.host(view, size: Self.size)
        defer { window.orderOut(nil) }
        return !Self.contentBackgrounds(in: window.contentView).isEmpty
    }

    private func fieldList() -> InspectorFieldListView {
        let state = MultiRowEditState()
        state.configure(
            rowIDs: [.existing(0)],
            allRows: [["1", "Still"]],
            absentCells: [[]],
            columns: ["id", "name"],
            columnTypes: [.integer(rawType: "INTEGER"), .text(rawType: "TEXT")],
            externallyModifiedColumns: []
        )
        return InspectorFieldListView(editState: state, isEditable: true, databaseType: .sqlite, userDefinedTypeScope: nil)
    }

    @Test("A plain list keeps its material where split items are not glass and drops it where they are")
    func modifierFollowsTheGlassRelease() {
        let list = List { Text(verbatim: "row") }.listStyle(.plain)
        #expect(drawsListMaterial(list))
        #expect(drawsListMaterial(list.splitItemGlassBackground()) == !ThemeWindowBackdrop.canReachChrome)
    }

    @Test("The inspector's field list lets the inspector glass show through on macOS 26 and later")
    func inspectorFieldListShowsTheGlass() {
        #expect(drawsListMaterial(fieldList()) == !ThemeWindowBackdrop.canReachChrome)
    }

    @Test("The agent's proposed statements let the trailing pane's glass show through on macOS 26 and later")
    func proposedStatementsShowTheGlass() {
        let statements = [ProposedStatement(id: "1", sql: "SELECT 1", toolName: "run_query", state: .ran)]
        #expect(drawsListMaterial(AgentProposedStatementsView(statements: statements)) == !ThemeWindowBackdrop.canReachChrome)
    }
}
