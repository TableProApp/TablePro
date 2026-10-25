import AppKit
import SwiftUI
import TableProEditorKit
import TableProGrammars
import TableProPluginKit
import TableProTheme

// The real editor and grid on a fixed scope, so the preview cannot disagree with a window.
internal struct ThemeEditorPreview: View {
    internal let scope: ThemeScope
    internal let appearance: ThemeAppearance
    // A fixed scope publishes no changes, so a font size set elsewhere reaches the preview only as a remount.
    @ObservedObject private var themeEngine = ThemeEngine.shared

    internal static let editorHeight: CGFloat = 150
    internal static let gridHeight: CGFloat = 150

    internal var body: some View {
        ThemePreviewAppearanceHost(appearance: appearance) {
            VStack(spacing: 0) {
                ThemePreviewEditor(scope: scope)
                    .frame(height: Self.editorHeight)
                Divider()
                ThemePreviewGrid(scope: scope)
                    .frame(height: Self.gridHeight)
            }
            .id([themeEngine.editorFonts.font, themeEngine.dataGridFonts.regular])
        }
        .frame(height: Self.editorHeight + Self.gridHeight + 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Theme Preview"))
        .accessibilityIdentifier("theme-editor-preview")
    }
}

// Never takes clicks or keyboard focus: a focused preview would answer Undo with its own empty history.
internal protocol ThemePreviewSurface: AnyObject {}

internal extension NSView {
    var isInsideThemePreview: Bool {
        var view: NSView? = self
        while let current = view {
            if current is ThemePreviewSurface { return true }
            view = current.superview
        }
        return false
    }
}

private final class ThemePreviewHostingView<Content: View>: NSHostingView<Content>, ThemePreviewSurface {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private struct ThemePreviewAppearanceHost<Content: View>: NSViewRepresentable {
    let appearance: ThemeAppearance
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> ThemePreviewHostingView<Content> {
        let view = ThemePreviewHostingView(rootView: content())
        view.sizingOptions = []
        view.appearance = Self.drawingAppearance(for: appearance)
        return view
    }

    func updateNSView(_ view: ThemePreviewHostingView<Content>, context: Context) {
        view.rootView = content()
        let drawing = Self.drawingAppearance(for: appearance)
        if view.appearance?.name != drawing?.name {
            view.appearance = drawing
        }
    }

    private static func drawingAppearance(for appearance: ThemeAppearance) -> NSAppearance? {
        NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
    }
}

// MARK: - Editor

internal enum ThemePreviewSample {
    internal static let sql = """
    -- Paid orders above a threshold
    SELECT c.name, COUNT(*) AS items, CAST(SUM(o.total) AS DECIMAL(10, 2))
    FROM orders AS o
    JOIN customers AS c ON c.id = o.customer_id
    WHERE o.status = 'paid'
    \tAND o.total >= 100 AND o.note IS NULL
    GROUP BY c.name;
    UPDATE customers SET active = TRUE WHERE id = 42;
    """

    private static var text: NSString { sql as NSString }

    internal static var statementRange: NSRange {
        let start = text.range(of: "SELECT").location
        let end = text.range(of: ";").location
        return NSRange(location: start, length: end + 1 - start)
    }

    internal static var cursorPositions: [CursorPosition] {
        let caretLine = text.range(of: "FROM orders")
        let selection = text.range(of: "'paid'")
        return [
            CursorPosition(range: NSRange(location: caretLine.location + 4, length: 0)),
            CursorPosition(range: selection),
        ]
    }
}

private struct ThemePreviewEditor: View {
    let scope: ThemeScope

    @State private var state = SourceEditorState(cursorPositions: ThemePreviewSample.cursorPositions)
    @State private var statementBand = ThemePreviewStatementBand()

    var body: some View {
        SourceEditor(
            .constant(ThemePreviewSample.sql),
            language: EditorLanguage.sql.treeSitterLanguage,
            configuration: configuration,
            state: $state,
            coordinators: [statementBand]
        )
    }

    private var configuration: SourceEditorConfiguration {
        var peripherals = EditorPeripherals.inline(lineNumbers: true, folding: false, invisibleCharacters: true)
        peripherals.invisibleCharactersConfiguration = InvisibleCharactersConfiguration(
            showSpaces: false,
            showTabs: true,
            showLineEndings: false
        )
        return SourceEditorConfiguration(
            appearance: .init(
                theme: EditorThemeFactory.make(
                    resolved: scope.resolved,
                    highlightsCurrentLine: true,
                    highlightsCurrentStatement: true
                ),
                font: ThemeEngine.shared.editorFonts.font,
                wrapLines: false
            ),
            behavior: .init(isEditable: false),
            layout: .init(contentInsets: NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)),
            peripherals: peripherals
        )
    }
}

@MainActor
private final class ThemePreviewStatementBand: TextViewCoordinator {
    func prepareCoordinator(controller: TextViewController) {
        controller.highlightedStatementRange = ThemePreviewSample.statementRange
    }

    func controllerDidAppear(controller: TextViewController) {
        controller.highlightedStatementRange = ThemePreviewSample.statementRange
    }
}

// MARK: - Grid

// Five rows that put every grid slot on screen: row numbers, both stripes, NULL, both booleans, an
// unfocused selection, and a modified, a deleted and an inserted row.
internal enum ThemePreviewGridSample {
    internal static let selectedRow = 1
    internal static let modifiedRow = 2
    internal static let modifiedColumn = 4
    internal static let deletedRow = 3
    internal static let insertedRow = 4

    internal static let tableRows: TableRows = {
        let values: [[PluginCellValue]] = [
            [.text("1"), .text("Ada Lovelace"), .text("ada@example.com"), .text("true"), .text("1250.00")],
            [.text("2"), .text("Alan Turing"), .null, .text("false"), .text("980.50")],
            [.text("3"), .text("Grace Hopper"), .text("grace@example.com"), .text("true"), .text("3100.75")],
            [.text("4"), .text("Edsger Dijkstra"), .text("edsger@example.com"), .text("false"), .text("0.00")],
            [.text("5"), .text("Barbara Liskov"), .text("barbara@example.com"), .text("true"), .null],
        ]
        let rows = values.enumerated().map { index, row in
            Row(
                id: index == insertedRow ? .inserted(UUID()) : .existing(index),
                values: ContiguousArray(row)
            )
        }
        return TableRows(
            rows: ContiguousArray(rows),
            columns: ["id", "name", "email", "active", "balance"],
            columnTypes: [
                .integer(rawType: "INTEGER"),
                .text(rawType: "TEXT"),
                .text(rawType: "TEXT"),
                .boolean(rawType: "BOOLEAN"),
                .decimal(rawType: "DECIMAL"),
            ]
        )
    }()

    // A preview: nothing to sort, filter or edit.
    internal static var configuration: DataGridConfiguration {
        var configuration = DataGridConfiguration()
        configuration.showRowNumbers = true
        configuration.supportsValueFilter = false
        configuration.supportsColumnSort = false
        return configuration
    }

    internal static func visualState(forRow row: Int) -> RowVisualState? {
        switch row {
        case modifiedRow:
            return RowVisualState(isDeleted: false, isInserted: false, modifiedColumns: [modifiedColumn])
        case deletedRow:
            return RowVisualState(isDeleted: true, isInserted: false, modifiedColumns: [])
        case insertedRow:
            return RowVisualState(isDeleted: false, isInserted: true, modifiedColumns: [])
        default:
            return nil
        }
    }
}

private struct ThemePreviewGrid: View {
    let scope: ThemeScope

    @StateObject private var grid: HeldRowsGridAdapter

    init(scope: ThemeScope) {
        self.scope = scope
        _grid = StateObject(wrappedValue: HeldRowsGridAdapter(
            configuration: ThemePreviewGridSample.configuration,
            themeScope: scope
        ))
    }

    // task(id:) runs with this body's scope; onChange(of:) would hand the grid the previous one (measured).
    var body: some View {
        DataGridView(model: grid.model)
            .task(id: ObjectIdentifier(scope)) { load() }
    }

    private func load() {
        if grid.model.themeScope !== scope {
            grid.model.themeScope = scope
        }
        guard grid.heldRows.rows.isEmpty else { return }
        let rows = ThemePreviewGridSample.tableRows
        var states: [RowID: RowVisualState] = [:]
        for (index, row) in rows.rows.enumerated() {
            states[row.id] = ThemePreviewGridSample.visualState(forRow: index)
        }
        grid.visualStates = states
        grid.setRows(rows)
        if rows.rows.indices.contains(ThemePreviewGridSample.selectedRow) {
            grid.model.selectRows([rows.rows[ThemePreviewGridSample.selectedRow].id])
        }
    }
}
