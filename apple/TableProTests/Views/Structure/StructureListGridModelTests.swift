import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct StructureListGridModelTests {
    private let columns = ["Name", "Timing"]
    private let rows = [
        StructureListRow(id: "a", values: ["alpha", "BEFORE"]),
        StructureListRow(id: "b", values: ["beta", "AFTER"]),
        StructureListRow(id: "c", values: ["gamma", "AFTER"]),
    ]

    private func load(
        _ model: StructureListGridModel<String>,
        _ rows: [StructureListRow<String>],
        sortState: SortState? = nil
    ) {
        model.load(
            columns: columns,
            rows: rows,
            defaultWidths: [],
            minimumWidths: [],
            databaseType: .mysql,
            sortState: sortState
        )
    }

    private func loadedModel() -> StructureListGridModel<String> {
        let model = StructureListGridModel<String>()
        load(model, rows)
        return model
    }

    private func displayedIDs(_ model: StructureListGridModel<String>) -> [String] {
        (0..<model.model.rowCount).compactMap { index in model.model.rowID(at: index).flatMap { model.id(for: $0) } }
    }

    private func displayRows(_ model: StructureListGridModel<String>, of ids: Set<String>) -> IndexSet {
        IndexSet(ids.compactMap { id in model.rowID(for: id).flatMap { model.model.displayIndex(of: $0) } })
    }

    @Test("Rows load in the order given, as text cells, and the same rows again change nothing")
    func loadsRowsInOrder() {
        let model = loadedModel()
        let revision = model.model.displayRevision

        #expect(model.tableRows.columns == columns)
        #expect(model.tableRows.rows.map { $0.values.map(\.asText) } == rows.map { $0.values.map(Optional.some) })
        #expect(model.rowIDs == ["a", "b", "c"])
        #expect(displayedIDs(model) == ["a", "b", "c"])

        load(model, rows)
        #expect(model.model.displayRevision == revision)

        load(model, rows.reversed())
        #expect(model.tableRows.rows.first?.values.first?.asText == "gamma")
        #expect(model.rowIDs == ["c", "b", "a"])
    }

    @Test("An id and its grid row map both ways, and an unknown one maps to nothing")
    func mapsRowsAndIDs() throws {
        let model = loadedModel()
        let second = try #require(model.model.rowID(at: 1))

        #expect(model.id(for: second) == "b")
        #expect(model.rowID(for: "b") == second)
        #expect(model.model.rowID(at: 3) == nil)
        #expect(model.rowID(for: "z") == nil)
        #expect(displayRows(model, of: ["c", "z"]) == [2])
        #expect(displayRows(model, of: []).isEmpty)
    }

    @Test("A list row keeps its grid row across a reload, so a reorder is not a new record")
    func rowIdentitySurvivesAReorder() throws {
        let model = loadedModel()
        let beta = try #require(model.rowID(for: "b"))

        load(model, rows.reversed())

        #expect(model.rowID(for: "b") == beta)
        #expect(model.model.displayIndex(of: beta) == 1)
    }

    @Test("A header sort reaches the owner of the rows")
    func forwardsSortToOwner() {
        let model = loadedModel()
        var received: SortState?
        model.grid.onSortChange = { received = $0 }
        let state = SortState(columns: [SortColumn(columnIndex: 1, direction: .descending)], source: .user)

        model.model.setSort(state)

        #expect(received == state)
        #expect(model.model.store.sortState == state)
    }

    @Test("A nil sort turns header sorting off, and a sort turns it on")
    func sortStateDecidesHeaderSorting() {
        let model = StructureListGridModel<String>()
        load(model, rows)
        #expect(!model.model.configuration.supportsColumnSort)

        load(model, rows, sortState: SortState())
        #expect(model.model.configuration.supportsColumnSort)
    }

    @Test("The owner's selection maps to grid rows, and a grid selection maps back to ids")
    func selectionMapsBothWays() throws {
        let model = loadedModel()
        var published: [Set<String>] = []
        model.onSelect = { published.append($0) }

        model.syncSelection(["b"])
        #expect(displayRows(model, of: model.selectedIDs) == [1])
        #expect(published.isEmpty)

        let first = try #require(model.model.rowID(at: 0))
        let third = try #require(model.model.rowID(at: 2))
        model.model.selectRows([first, third])
        #expect(published.last == ["a", "c"])
        #expect(model.selectedIDs == ["a", "c"])
    }

    @Test("A reload that keeps the selected records publishes nothing to the owner")
    func reloadKeepsTheIDsWithoutPublishing() {
        let model = loadedModel()
        var published: [Set<String>] = []
        model.onSelect = { published.append($0) }
        model.syncSelection(["a", "b"])

        load(model, rows.reversed())

        #expect(published.isEmpty)
        #expect(model.selectedIDs == ["a", "b"])
        #expect(displayRows(model, of: ["a", "b"]) == [1, 2])
    }

    // A filtered list republishing what it shows used to drop the selected ids the filter hid.
    @Test("Syncing ids a filter hides keeps them for the owner")
    func syncKeepsHiddenIDs() {
        let model = loadedModel()
        var published: [Set<String>] = []
        model.onSelect = { published.append($0) }

        model.syncSelection(["a", "hidden"])

        #expect(published.isEmpty)
        #expect(model.selectedIDs == ["a"])
    }

    @Test("Default widths fill only the columns the layout has no width for")
    func defaultWidthsFillMissingColumns() {
        var stored = ColumnLayoutState()
        stored.columnWidths["Timing"] = 300

        let layout = StructureListGrid<String>.layout(stored, columns: columns, defaultWidths: [220, 90])

        #expect(layout.columnWidths == ["Name": 220, "Timing": 300])
        #expect(StructureListGrid<String>.layout(stored, columns: columns, defaultWidths: []) == stored)
    }

    @Test("A width the reader set survives a reload of the same columns")
    func readerWidthSurvivesAReload() {
        let model = StructureListGridModel<String>()
        model.load(columns: columns, rows: rows, defaultWidths: [220, 90], minimumWidths: [], databaseType: .mysql, sortState: nil)
        model.model.updateColumnLayout { $0.columnWidths["Name"] = 400 }

        model.load(columns: columns, rows: Array(rows.prefix(2)), defaultWidths: [220, 90], minimumWidths: [], databaseType: .mysql, sortState: nil)

        #expect(model.model.store.columnLayout.columnWidths["Name"] == 400)
        #expect(model.model.store.layoutScope == .ephemeral)
    }

    @Test("Minimum widths follow the columns by index and name nothing past them")
    func minimumWidthsFollowColumns() {
        #expect(StructureListGrid<String>.minimumWidths([140, 70], columns: columns) == ["Name": 140, "Timing": 70])
        #expect(StructureListGrid<String>.minimumWidths([140], columns: columns) == ["Name": 140])
        #expect(StructureListGrid<String>.minimumWidths([], columns: columns).isEmpty)
    }

    @Test("A spoken value is answered for its row and column, and nothing else is")
    func answersSpokenValues() throws {
        let model = StructureListGridModel<String>()
        load(model, [
            StructureListRow(id: "a", values: ["alpha", "YES"], spokenValues: [1: "Enabled"]),
            StructureListRow(id: "b", values: ["beta", "NO"]),
        ])
        let first = try #require(model.model.rowID(at: 0))
        let second = try #require(model.model.rowID(at: 1))
        let name = try #require(model.model.columns.column(at: 0))
        let timing = try #require(model.model.columns.column(at: 1))

        #expect(model.grid.gridAccessibilityText(for: first, column: timing) == "Enabled")
        #expect(model.grid.gridAccessibilityText(for: first, column: name) == nil)
        #expect(model.grid.gridAccessibilityText(for: second, column: timing) == nil)
        #expect(model.grid.gridAccessibilityText(for: .existing(99), column: timing) == nil)
    }

    @Test("The list is read-only, never takes a commit, and offers no row commands")
    func listIsReadOnly() throws {
        let model = loadedModel()
        let first = try #require(model.model.rowID(at: 0))
        let name = try #require(model.model.columns.column(at: 0))

        #expect(!model.model.configuration.isEditable)
        #expect(!model.model.commit([DataGridCellEdit(rowID: first, columnID: name.id, value: .enteredText("x"))], actionName: "Edit"))
        #expect(model.model.configuration.commands == [.freezeColumns])
        #expect(model.tableRows.rows.first?.values.first?.asText == "alpha")
    }
}

@MainActor
struct StructureListGridToneTests {
    private let palette = DataGridCellPalette(
        regularFont: .systemFont(ofSize: 13),
        italicFont: .systemFont(ofSize: 13),
        mediumFont: .systemFont(ofSize: 13, weight: .medium),
        text: .systemPurple,
        placeholderText: .systemBrown,
        booleanTrueText: .labelColor,
        booleanFalseText: .labelColor,
        rowNumberText: .secondaryLabelColor,
        deletedRowText: .systemPink,
        modifiedColumnTint: .systemYellow,
        findMatchTint: .systemOrange,
        selectionText: .systemIndigo
    )

    private func appearance(
        tone: NSColor?,
        placeholder: DataGridCellPlaceholder? = nil,
        visualState: RowVisualState = .empty,
        isCurrentFindMatch: Bool = false,
        onEmphasizedSelection: Bool = false
    ) -> DataGridCellAppearance {
        DataGridCellAppearance.resolve(
            kind: .text,
            content: DataGridCellContent(displayText: "active", rawValue: "active", placeholder: placeholder),
            state: DataGridCellState(
                visualState: visualState,
                isEditable: false,
                isCurrentFindMatch: isCurrentFindMatch,
                row: 0,
                columnIndex: 0
            ),
            palette: palette,
            nullDisplayString: "NULL",
            onEmphasizedSelection: onEmphasizedSelection,
            textTone: tone
        )
    }

    @Test("Each tone is a system status color")
    func tonesAreSystemColors() {
        #expect(StructureListTone.positive.color == .systemGreen)
        #expect(StructureListTone.caution.color == .systemOrange)
        #expect(StructureListTone.critical.color == .systemRed)
        #expect(StructureListTone.secondary.color == .secondaryLabelColor)
    }

    @Test("A tone is answered for its own cell, and a row without tones answers none")
    func modelAnswersTonePerCell() throws {
        let model = StructureListGridModel<String>()
        model.load(
            columns: ["Name", "State"],
            rows: [
                StructureListRow(id: "a", values: ["alpha", "active"], tones: [1: .positive]),
                StructureListRow(id: "b", values: ["beta", "idle"]),
            ],
            defaultWidths: [],
            minimumWidths: [],
            databaseType: .mysql,
            sortState: nil
        )
        let first = try #require(model.model.rowID(at: 0))
        let second = try #require(model.model.rowID(at: 1))
        let name = try #require(model.model.columns.column(at: 0))
        let state = try #require(model.model.columns.column(at: 1))

        #expect(model.grid.gridTextTone(for: first, column: state) == .systemGreen)
        #expect(model.grid.gridTextTone(for: first, column: name) == nil)
        #expect(model.grid.gridTextTone(for: second, column: state) == nil)
        #expect(model.grid.gridTextTone(for: .existing(99), column: state) == nil)
    }

    @Test("A toned value draws in its tone and turns to the selection text on an emphasized selection")
    func toneGivesWayToTheSelection() {
        #expect(appearance(tone: .systemGreen).textColor == .systemGreen)
        #expect(appearance(tone: .systemGreen, onEmphasizedSelection: true).textColor == .systemIndigo)
        #expect(appearance(tone: nil).textColor == .systemPurple)
    }

    @Test("A placeholder, a deleted row and a find match keep their own text color over a tone")
    func toneLeavesOtherStatesAlone() {
        let deleted = RowVisualState(isDeleted: true, isInserted: false, modifiedColumns: [])

        #expect(appearance(tone: .systemGreen, placeholder: .empty).textColor == .systemBrown)
        #expect(appearance(tone: .systemGreen, visualState: deleted).textColor == .systemPink)
        #expect(appearance(tone: .systemGreen, isCurrentFindMatch: true).textColor == palette.findMatchText)
    }
}
