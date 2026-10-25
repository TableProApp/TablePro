//
//  DataGridTestFixture.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import TableProPluginKit

// A data source and owner that records every request the grid makes of it.
@MainActor
final class GridTestOwner: DataGridDataSource, DataGridActions {
    var tableRows: TableRows
    let changeManager: DataChangeManager
    let changeState: AnyChangeManager
    weak var model: DataGridModel?

    var rowNumberOffset = 0
    var highlightRules: [HighlightRule] = []
    var visualStates: [RowID: RowVisualState] = [:]
    var checkboxStates: [RowID: Bool] = [:]
    var approvesDisplayOrderChange = true
    var acceptsCommits = true
    // Records each committed value, writes it into the rows and reports it back, the way a real owner does.
    var appliesCommits = false

    private(set) var commits: [(edits: [DataGridResolvedEdit], actionName: String)] = []
    private(set) var deleteRequests: [[RowID]] = []
    private(set) var sortChanges: [SortState] = []
    private(set) var displayOrderRequests = 0
    private(set) var searchedTerms: [String] = []
    private(set) var checkboxWrites: [(isOn: Bool, rowIDs: [RowID], column: String)] = []
    private(set) var addRowRequests = 0
    private(set) var movedRows: [(rowID: RowID, destination: Int)] = []

    init(_ tableRows: TableRows, changeManager: DataChangeManager = DataChangeManager()) {
        self.tableRows = tableRows
        self.changeManager = changeManager
        changeState = AnyChangeManager(changeManager)
    }

    var gridRows: TableRows { tableRows }
    var gridChangeState: AnyChangeManager { changeState }
    var gridRowNumberOffset: Int { rowNumberOffset }
    var gridHighlightRules: [HighlightRule] { highlightRules }

    func gridVisualState(for rowID: RowID) -> RowVisualState? {
        visualStates[rowID]
    }

    func gridCheckboxState(for rowID: RowID, column: DataGridColumn) -> Bool? {
        checkboxStates[rowID]
    }

    func gridCommit(_ edits: [DataGridResolvedEdit], actionName: String) -> Bool {
        commits.append((edits, actionName))
        guard acceptsCommits else { return false }
        guard appliesCommits else { return true }
        var changed: Set<CellPosition> = []
        for edit in edits {
            guard let index = tableRows.index(of: edit.rowID) else { continue }
            changeManager.recordCellChange(
                rowID: edit.rowID,
                columnIndex: edit.dataIndex,
                columnName: edit.columnName,
                oldValue: edit.oldValue,
                newValue: edit.newValue,
                originalRow: edit.originalRow,
                absence: edit.absence,
                isExpression: edit.isExpression
            )
            _ = tableRows.edit(row: index, column: edit.dataIndex, value: edit.newValue)
            changed.insert(CellPosition(row: index, column: edit.dataIndex))
        }
        model?.apply(.cellsChanged(changed))
        return true
    }

    func gridDeleteRows(_ rowIDs: [RowID]) {
        deleteRequests.append(rowIDs)
    }

    func gridSortDidChange(_ sort: SortState) {
        sortChanges.append(sort)
    }

    func gridConfirmDisplayOrderChange(then apply: @escaping @MainActor () -> Void) {
        displayOrderRequests += 1
        if approvesDisplayOrderChange {
            apply()
        }
    }

    func gridSearchAllRows(term: String) {
        searchedTerms.append(term)
    }

    func gridSetCheckbox(_ isOn: Bool, rowIDs: [RowID], column: DataGridColumn) {
        checkboxWrites.append((isOn, rowIDs, column.name))
        for rowID in rowIDs {
            checkboxStates[rowID] = isOn
        }
    }

    func gridAddRow() {
        addRowRequests += 1
    }

    func gridMoveRow(from source: RowID, toDisplayIndex destination: Int) {
        movedRows.append((source, destination))
    }
}

// The headless host never gives a window the keyboard, so key state is stated here instead.
@MainActor
final class GridTestWindow: NSWindow {
    var holdsKeyboard = true

    override var isKeyWindow: Bool { holdsKeyboard }
    override var canBecomeKey: Bool { true }
}

// A DataGridViewController mounted in a window, over a model whose owner is a GridTestOwner.
@MainActor
final class HostedDataGrid {
    let owner: GridTestOwner
    let model: DataGridModel
    let controller: DataGridViewController
    let window: GridTestWindow

    init(
        rows: TableRows,
        configuration: DataGridConfiguration = DataGridConfiguration(),
        store: any DataGridStateStore = InMemoryDataGridStateStore(),
        changeManager: DataChangeManager = DataChangeManager(),
        size: NSSize = NSSize(width: 800, height: 400),
        prepare: (GridTestOwner, DataGridModel) -> Void = { _, _ in }
    ) {
        owner = GridTestOwner(rows, changeManager: changeManager)
        model = DataGridModel(store: store, configuration: configuration)
        model.dataSource = owner
        model.actions = owner
        owner.model = model
        prepare(owner, model)
        model.reloadRows()

        controller = DataGridViewController(model: model)
        window = GridTestWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = content
        controller.view.frame = content.bounds
        controller.view.autoresizingMask = [.width, .height]
        content.addSubview(controller.view)
        layout()
    }

    var container: DataGridContainerView { controller.container }
    var main: DataGridTableView { controller.main.tableView }
    var frozen: DataGridTableView { controller.frozen.tableView }
    var mainScrollView: DataGridScrollView { controller.main.scrollView }
    var frozenScrollView: DataGridScrollView { controller.frozen.scrollView }

    // Lays the container out and has both tables prepare the rows on screen.
    func layout() {
        window.contentView?.layoutSubtreeIfNeeded()
        container.layoutSubtreeIfNeeded()
        for pane in controller.panes {
            pane.scrollView.layoutSubtreeIfNeeded()
            pane.tableView.layoutSubtreeIfNeeded()
        }
    }

    @discardableResult
    func focus() -> Bool {
        let accepted = window.makeFirstResponder(main)
        container.refreshFocus()
        return accepted
    }

    func setKeyWindow(_ isKey: Bool) {
        window.holdsKeyboard = isKey
        container.refreshFocus()
    }

    // The table column that shows a display position in a pane, row numbers included.
    func tableIndex(ofDisplayPosition position: Int, in kind: DataGridPane.Kind = .main) -> Int? {
        controller.container.pane(kind).tableIndex(forDisplayPosition: position, columns: model.columns)
    }

    func tableColumn(named name: String, in kind: DataGridPane.Kind = .main) -> NSTableColumn? {
        let pane = controller.container.pane(kind)
        return pane.tableView.tableColumns.first { pane.columnID(of: $0)?.name == name }
    }

    func keyEvent(
        _ characters: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    // Delivers a key press to the main table the way the window would.
    @discardableResult
    func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> Bool {
        guard let event = keyEvent(characters, keyCode: keyCode, modifiers: modifiers) else { return false }
        main.keyDown(with: event)
        return true
    }

    // NSApp.currentEvent is the last event dequeued, so this leaves one carrying the modifiers in place.
    func setCurrentEventModifiers(_ modifiers: NSEvent.ModifierFlags) {
        guard let event = NSEvent.otherEvent(
            with: .applicationDefined,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0
        ) else { return }
        NSApp.postEvent(event, atStart: true)
        _ = NSApp.nextEvent(matching: .applicationDefined, until: .distantPast, inMode: .default, dequeue: true)
    }

    func close() {
        controller.dismantle()
        window.orderOut(nil)
    }
}

enum GridFixtureRows {
    static let people: TableRows = TableRows.from(
        queryRows: [
            ["0", "ann", "30"],
            ["1", "bob", "41"],
            ["2", "cid", "25"],
            ["3", "dee", "33"],
            ["4", "eve", "52"],
        ],
        columns: ["id", "name", "age"],
        columnTypes: [.integer(rawType: "INT"), .text(rawType: "TEXT"), .integer(rawType: "INT")]
    )

    // Enough rows and columns to scroll both ways in an 800 by 400 window.
    static func wide(rows rowCount: Int = 80, columns columnCount: Int = 12) -> TableRows {
        let columns = (0..<columnCount).map { "c\($0)" }
        let values: [[PluginCellValue]] = (0..<rowCount).map { row in
            (0..<columnCount).map { column in .text("r\(row) value in column \(column)") }
        }
        return TableRows.from(
            queryRows: values,
            columns: columns,
            columnTypes: Array(repeating: .text(rawType: "TEXT"), count: columnCount)
        )
    }

    static func nameFilter(_ names: Set<String>) -> GridValueFilterState {
        var filter = GridValueFilterState()
        filter.set(ColumnValueFilter(selectedValues: names, includesNull: false), columnName: "name", forColumn: 1)
        return filter
    }
}
