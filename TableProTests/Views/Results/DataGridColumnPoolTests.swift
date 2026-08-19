//
//  DataGridColumnPoolTests.swift
//  TableProTests
//

import AppKit
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("DataGridColumnPool")
@MainActor
struct DataGridColumnPoolTests {
    private func makeTableView() -> NSTableView {
        let tableView = NSTableView()
        // Mirrors DataGridView. The default style redistributes column widths on resize, which
        // would silently rewrite the widths these tests assert on.
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        let rowNumberColumn = NSTableColumn(identifier: ColumnIdentitySchema.rowNumberIdentifier)
        rowNumberColumn.width = 40
        tableView.addTableColumn(rowNumberColumn)
        return tableView
    }

    private func makeColumnTypes(count: Int) -> [ColumnType] {
        Array(repeating: ColumnType.text(rawType: nil), count: count)
    }

    private func defaultWidthCalculator(name: String, slot: Int) -> CGFloat {
        100
    }

    private func dataColumns(in tableView: NSTableView) -> [NSTableColumn] {
        tableView.tableColumns.filter {
            $0.identifier != ColumnIdentitySchema.rowNumberIdentifier
                && !ColumnIdentitySchema.isSpacer($0.identifier)
        }
    }

    @Test("reconcile grows pool when column count exceeds capacity")
    func reconcile_growsPoolWhenColumnCountExceedsCapacity() {
        let pool = DataGridColumnPool()
        let tableView = makeTableView()
        let schema = ColumnIdentitySchema(columns: ["id", "name", "email"])

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 3),
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )

        #expect(pool.totalSlots == 3)
        #expect(dataColumns(in: tableView).count == 3)
    }

    @Test("reconcile does not shrink pool when column count drops")
    func reconcile_doesNotShrinkPoolWhenColumnCountDrops() {
        let pool = DataGridColumnPool()
        let tableView = makeTableView()

        pool.reconcile(
            tableView: tableView,
            schema: ColumnIdentitySchema(columns: ["a", "b", "c", "d"]),
            columnTypes: makeColumnTypes(count: 4),
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )
        #expect(pool.totalSlots == 4)

        pool.reconcile(
            tableView: tableView,
            schema: ColumnIdentitySchema(columns: ["a", "b"]),
            columnTypes: makeColumnTypes(count: 2),
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )

        #expect(pool.totalSlots == 4)
        let extras = dataColumns(in: tableView).filter { column in
            let identifier = column.identifier.rawValue
            return identifier == "dataColumn-2" || identifier == "dataColumn-3"
        }
        #expect(extras.count == 2)
        #expect(extras.allSatisfy { $0.isHidden })
    }

    @Test("reconcile attaches columns in natural order when no saved layout")
    func reconcile_attachesColumnsInNaturalOrderWithoutSavedLayout() {
        let pool = DataGridColumnPool()
        let tableView = makeTableView()
        let schema = ColumnIdentitySchema(columns: ["id", "name", "email"])

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 3),
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )

        let identifiers = dataColumns(in: tableView).map(\.identifier.rawValue)
        #expect(identifiers == ["dataColumn-0", "dataColumn-1", "dataColumn-2"])
    }

    @Test("reconcile attaches columns in saved order on first call")
    func reconcile_attachesColumnsInSavedOrderOnFirstCall() {
        let pool = DataGridColumnPool()
        let tableView = makeTableView()
        let schema = ColumnIdentitySchema(columns: ["id", "name", "email"])

        var layout = ColumnLayoutState()
        layout.columnOrder = ["email", "id", "name"]

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 3),
            savedLayout: layout,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )

        let identifiers = dataColumns(in: tableView).map(\.identifier.rawValue)
        #expect(identifiers == ["dataColumn-2", "dataColumn-0", "dataColumn-1"])
    }

    @Test("reconcile reorders existing columns when saved order differs from current")
    func reconcile_reordersExistingColumnsWhenSavedOrderDiffersFromCurrent() {
        let pool = DataGridColumnPool()
        let tableView = makeTableView()
        let schema = ColumnIdentitySchema(columns: ["id", "name", "email"])

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 3),
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )

        var layout = ColumnLayoutState()
        layout.columnOrder = ["email", "id", "name"]

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 3),
            savedLayout: layout,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )

        let identifiers = dataColumns(in: tableView).map(\.identifier.rawValue)
        #expect(identifiers == ["dataColumn-2", "dataColumn-0", "dataColumn-1"])

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 3),
            savedLayout: layout,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )

        let afterSecond = dataColumns(in: tableView).map(\.identifier.rawValue)
        #expect(afterSecond == ["dataColumn-2", "dataColumn-0", "dataColumn-1"])
    }

    @Test("reconcile reuses the same NSTableColumn instances across calls")
    func reconcile_reusesSameTableColumnInstancesAcrossCalls() {
        let pool = DataGridColumnPool()
        let tableView = makeTableView()
        let schema = ColumnIdentitySchema(columns: ["id", "name", "email"])

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 3),
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )

        let firstSnapshot = dataColumns(in: tableView)
        let capturedSlot1 = firstSnapshot[1]

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 3),
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )

        let afterSnapshot = dataColumns(in: tableView)
        #expect(afterSnapshot[1] === capturedSlot1)
        for (before, after) in zip(firstSnapshot, afterSnapshot) {
            #expect(before === after)
        }
    }

    @Test("reconcile honors hidden columns from saved layout")
    func reconcile_honorsHiddenColumnsFromSavedLayout() {
        let pool = DataGridColumnPool()
        let tableView = makeTableView()
        let schema = ColumnIdentitySchema(columns: ["id", "name", "email"])

        var layout = ColumnLayoutState()
        layout.hiddenColumns = ["name"]

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 3),
            savedLayout: layout,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )

        let columns = dataColumns(in: tableView)
        let hiddenStateByName = Dictionary(uniqueKeysWithValues: columns.map { ($0.headerCell.stringValue, $0.isHidden) })
        #expect(hiddenStateByName["id"] == false)
        #expect(hiddenStateByName["name"] == true)
        #expect(hiddenStateByName["email"] == false)
    }

    @Test("reconcile honors hidden columns from hiddenColumnNames parameter")
    func reconcile_honorsHiddenColumnsFromParameter() {
        let pool = DataGridColumnPool()
        let tableView = makeTableView()
        let schema = ColumnIdentitySchema(columns: ["id", "name", "email"])

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 3),
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: ["email"],
            widthCalculator: defaultWidthCalculator
        )

        let columns = dataColumns(in: tableView)
        let hiddenStateByName = Dictionary(uniqueKeysWithValues: columns.map { ($0.headerCell.stringValue, $0.isHidden) })
        #expect(hiddenStateByName["id"] == false)
        #expect(hiddenStateByName["name"] == false)
        #expect(hiddenStateByName["email"] == true)
    }

    @Test("Slot identifiers use dataColumn-N format")
    func reconcile_slotIdentifierFormatIsDataColumnN() {
        let pool = DataGridColumnPool()
        let tableView = makeTableView()
        let schema = ColumnIdentitySchema(columns: ["id", "name", "email", "created"])

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 4),
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )

        let identifiers = dataColumns(in: tableView).map(\.identifier.rawValue).sorted()
        #expect(identifiers == ["dataColumn-0", "dataColumn-1", "dataColumn-2", "dataColumn-3"])
    }

    @Test("Column width comes from widthCalculator when no saved widths")
    func reconcile_widthFromCalculatorWhenNoSavedWidths() {
        let pool = DataGridColumnPool()
        let tableView = makeTableView()
        let schema = ColumnIdentitySchema(columns: ["id", "name"])

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 2),
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: { name, _ in name == "id" ? 50 : 200 }
        )

        let widthsByName = Dictionary(uniqueKeysWithValues: dataColumns(in: tableView).map { ($0.headerCell.stringValue, $0.width) })
        #expect(widthsByName["id"] == 50)
        #expect(widthsByName["name"] == 200)
    }

    @Test("Column width comes from saved layout when present")
    func reconcile_widthFromSavedLayoutWhenPresent() {
        let pool = DataGridColumnPool()
        let tableView = makeTableView()
        let schema = ColumnIdentitySchema(columns: ["id", "name"])

        var layout = ColumnLayoutState()
        layout.columnWidths = ["id": 75, "name": 250]

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 2),
            savedLayout: layout,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: { _, _ in 9_999 }
        )

        let widthsByName = Dictionary(uniqueKeysWithValues: dataColumns(in: tableView).map { ($0.headerCell.stringValue, $0.width) })
        #expect(widthsByName["id"] == 75)
        #expect(widthsByName["name"] == 250)
    }

    @Test("A partial saved layout leaves missing columns automatic")
    func reconcile_partialSavedLayoutUsesCalculatorForMissingColumns() {
        let pool = DataGridColumnPool()
        let tableView = makeTableView()
        let schema = ColumnIdentitySchema(columns: ["id", "name"])
        var calculatedNames: [String] = []

        var layout = ColumnLayoutState()
        layout.columnWidths = ["id": 75]

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 2),
            savedLayout: layout,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: { name, _ in
                calculatedNames.append(name)
                return 200
            }
        )

        let widthsByName = Dictionary(
            uniqueKeysWithValues: dataColumns(in: tableView).map { ($0.headerCell.stringValue, $0.width) }
        )
        #expect(widthsByName["id"] == 75)
        #expect(widthsByName["name"] == 200)
        #expect(calculatedNames == ["name"])
    }

    @Test("An oversized saved width is clamped to the column ceiling")
    func reconcile_clampsOversizedSavedWidthToColumnCeiling() {
        let pool = DataGridColumnPool()
        let tableView = makeTableView()
        let schema = ColumnIdentitySchema(columns: ["id", "payload"])

        var layout = ColumnLayoutState()
        layout.columnWidths = ["id": 75, "payload": 28_000]

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 2),
            savedLayout: layout,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )

        let widthsByName = Dictionary(uniqueKeysWithValues: dataColumns(in: tableView).map { ($0.headerCell.stringValue, $0.width) })
        #expect(widthsByName["id"] == 75)
        #expect(widthsByName["payload"] == DataGridMetrics.dataColumnMaxWidth)
    }

    @Test("Data columns carry the min and max width bounds")
    func reconcile_dataColumnsCarryWidthBounds() {
        let pool = DataGridColumnPool()
        let tableView = makeTableView()

        pool.reconcile(
            tableView: tableView,
            schema: ColumnIdentitySchema(columns: ["id", "name"]),
            columnTypes: makeColumnTypes(count: 2),
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )

        for column in dataColumns(in: tableView) {
            #expect(column.minWidth == DataGridMetrics.dataColumnMinWidth)
            #expect(column.maxWidth == DataGridMetrics.dataColumnMaxWidth)
        }
    }

    @Test("reconcile publishes column comments to the header view")
    func reconcile_publishesColumnCommentsToHeaderView() throws {
        let pool = DataGridColumnPool()
        let tableView = makeTableView()
        let headerView = SortableHeaderView(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        tableView.headerView = headerView
        let schema = ColumnIdentitySchema(columns: ["id", "email"])

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 2),
            columnComments: ["email": "Primary contact address"],
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )

        let emailColumn = try #require(dataColumns(in: tableView).first { $0.headerCell.stringValue == "email" })
        let headerCell = try #require(emailColumn.headerCell as? SortableHeaderCell)
        #expect(headerView.comment(for: headerCell) == "Primary contact address")
        #expect(emailColumn.headerToolTip == "email (Text)\nPrimary contact address")
        #expect(headerCell.accessibilityLabel() == "Column: email, Primary contact address")

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 2),
            columnComments: [:],
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )

        #expect(headerView.comment(for: headerCell) == nil)
        #expect(emailColumn.headerToolTip == "email (Text)")
        #expect(headerCell.accessibilityLabel() == "Column: email")
    }

    @Test("reconcile expands and restores header height based on visible comments")
    func reconcile_updatesHeaderHeightForVisibleComments() {
        let pool = DataGridColumnPool()
        let tableView = makeTableView()
        let naturalHeight: CGFloat = 28
        let headerView = SortableHeaderView(
            frame: NSRect(x: 0, y: 0, width: 200, height: naturalHeight)
        )
        tableView.headerView = headerView
        let schema = ColumnIdentitySchema(columns: ["id", "email"])

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 2),
            columnComments: ["email": "Primary contact address"],
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )

        #expect(headerView.commentHeaderHeight > naturalHeight)
        #expect(headerView.frame.height == headerView.commentHeaderHeight)

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 2),
            columnComments: ["email": "Primary contact address"],
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: ["email"],
            widthCalculator: defaultWidthCalculator
        )

        #expect(headerView.frame.height == naturalHeight)
    }

    @Test("comments arriving after the first reconcile grow the header and repaint it")
    func reconcile_appliesCommentsArrivingAfterFirstLoad() throws {
        let pool = DataGridColumnPool()
        let tableView = makeTableView()
        let naturalHeight: CGFloat = 28
        let headerView = SortableHeaderView(
            frame: NSRect(x: 0, y: 0, width: 200, height: naturalHeight)
        )
        tableView.headerView = headerView
        let schema = ColumnIdentitySchema(columns: ["id", "email"])

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 2),
            columnComments: [:],
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )

        #expect(headerView.frame.height == naturalHeight)

        headerView.needsDisplay = false
        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 2),
            columnComments: ["email": "Primary contact address"],
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )

        let emailColumn = try #require(dataColumns(in: tableView).first { $0.headerCell.stringValue == "email" })
        let headerCell = try #require(emailColumn.headerCell as? SortableHeaderCell)
        #expect(headerView.comment(for: headerCell) == "Primary contact address")
        #expect(headerView.frame.height == headerView.commentHeaderHeight)
    }

    @Test("an edited comment reaches the header cell without changing the header height")
    func reconcile_appliesEditedCommentAtUnchangedHeaderHeight() throws {
        let pool = DataGridColumnPool()
        let tableView = makeTableView()
        let headerView = SortableHeaderView(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        tableView.headerView = headerView
        let schema = ColumnIdentitySchema(columns: ["id", "email"])

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 2),
            columnComments: ["email": "Primary contact address"],
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )

        let heightAfterFirstReconcile = headerView.frame.height

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 2),
            columnComments: ["email": "Work address"],
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )

        let emailColumn = try #require(dataColumns(in: tableView).first { $0.headerCell.stringValue == "email" })
        let headerCell = try #require(emailColumn.headerCell as? SortableHeaderCell)
        #expect(headerView.comment(for: headerCell) == "Work address")
        #expect(emailColumn.headerToolTip == "email (Text)\nWork address")
        #expect(headerView.frame.height == heightAfterFirstReconcile)
    }

    @Test("reconcile is idempotent for equivalent inputs")
    func reconcile_isIdempotentForEquivalentInputs() {
        let pool = DataGridColumnPool()
        let tableView = makeTableView()
        let schema = ColumnIdentitySchema(columns: ["id", "name", "email"])

        var layout = ColumnLayoutState()
        layout.columnOrder = ["name", "id", "email"]
        layout.columnWidths = ["id": 60, "name": 120, "email": 180]

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 3),
            savedLayout: layout,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )

        let beforeIdentifiers = tableView.tableColumns.map(\.identifier.rawValue)
        let beforeWidths = tableView.tableColumns.map(\.width)

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 3),
            savedLayout: layout,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )

        let afterIdentifiers = tableView.tableColumns.map(\.identifier.rawValue)
        let afterWidths = tableView.tableColumns.map(\.width)

        #expect(beforeIdentifiers == afterIdentifiers)
        #expect(beforeWidths == afterWidths)
    }

    @Test("detachFromTableView removes pool columns and allows clean re-attach")
    func detachFromTableView_removesPoolColumnsAndAllowsCleanReattach() {
        let pool = DataGridColumnPool()
        let tableView = makeTableView()
        let schema = ColumnIdentitySchema(columns: ["id", "name", "email"])

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 3),
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )
        #expect(dataColumns(in: tableView).count == 3)

        pool.detachFromTableView()
        #expect(dataColumns(in: tableView).isEmpty)
        #expect(pool.totalSlots == 3)

        pool.reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: makeColumnTypes(count: 3),
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: defaultWidthCalculator
        )
        #expect(dataColumns(in: tableView).count == 3)
        #expect(pool.totalSlots == 3)
    }

    // MARK: - Column windowing (#1219)

    private func makeScrolledTableView(viewportWidth: CGFloat) -> (NSScrollView, NSTableView) {
        let tableView = makeTableView()
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: viewportWidth, height: 600))
        scrollView.documentView = tableView
        scrollView.hasHorizontalScroller = true
        scrollView.layoutSubtreeIfNeeded()
        return (scrollView, tableView)
    }

    private func reconcileWide(
        _ pool: DataGridColumnPool,
        tableView: NSTableView,
        count: Int,
        hidden: Set<String> = []
    ) {
        let names = (0..<count).map { "c\($0)" }
        pool.reconcile(
            tableView: tableView,
            schema: ColumnIdentitySchema(columns: names),
            columnTypes: makeColumnTypes(count: count),
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: hidden,
            widthCalculator: defaultWidthCalculator
        )
    }

    private func spacerWidth(in tableView: NSTableView) -> CGFloat {
        tableView.tableColumns
            .filter { ColumnIdentitySchema.isSpacer($0.identifier) }
            .reduce(0) { $0 + $1.width }
    }

    /// NSTableView builds a cell view per non-hidden column for every prepared row, so the whole
    /// point is that a wide result leaves most columns unmounted.
    @Test("A wide result mounts far fewer columns than it has")
    func wideResultMountsAWindow() {
        let pool = DataGridColumnPool()
        let (_, tableView) = makeScrolledTableView(viewportWidth: 800)

        reconcileWide(pool, tableView: tableView, count: 500)

        let mounted = dataColumns(in: tableView).filter { !$0.isHidden }
        #expect(mounted.count < 60)
        #expect(!mounted.isEmpty)
    }

    /// The spacers exist so the horizontal scroller still spans the whole result. Lose this and the
    /// user cannot reach the columns the window left out.
    @Test("The spacers restore the width the window left out")
    func spacersPreserveDocumentWidth() {
        let pool = DataGridColumnPool()
        let (_, tableView) = makeScrolledTableView(viewportWidth: 800)

        reconcileWide(pool, tableView: tableView, count: 500)

        // A visible column occupies its width plus one intercell gap; a hidden one occupies
        // nothing. The spacers stand in for the unmounted columns, gaps included, so the two
        // layouts have to come to the same total.
        let gap = tableView.intercellSpacing.width
        let columns = dataColumns(in: tableView)
        let everyColumnSlot = columns.reduce(0) { $0 + $1.width + gap }
        let occupied = tableView.tableColumns
            .filter { !$0.isHidden && $0.identifier != ColumnIdentitySchema.rowNumberIdentifier }
            .reduce(0) { $0 + $1.width + gap }

        #expect(columns.count == 500)
        #expect(spacerWidth(in: tableView) > 0)
        #expect(columns.filter { !$0.isHidden }.count < columns.count)
        #expect(occupied == everyColumnSlot)
    }

    @Test("A narrow result mounts every column and needs no spacer")
    func narrowResultMountsEverything() {
        let pool = DataGridColumnPool()
        let (_, tableView) = makeScrolledTableView(viewportWidth: 800)

        reconcileWide(pool, tableView: tableView, count: 4)

        let allMounted = dataColumns(in: tableView).allSatisfy { !$0.isHidden }
        #expect(allMounted)
        #expect(spacerWidth(in: tableView) == 0)
    }

    /// A window slide must never bring back a column the user hid, which is the one way windowing
    /// could corrupt the visible column set.
    @Test("Windowing never un-hides a column the user hid")
    func windowNeverUnhidesUserHiddenColumn() {
        let pool = DataGridColumnPool()
        let (scrollView, tableView) = makeScrolledTableView(viewportWidth: 800)

        reconcileWide(pool, tableView: tableView, count: 500, hidden: ["c0", "c1", "c2"])
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
        pool.applyColumnWindow(in: tableView)

        let hiddenByUser = dataColumns(in: tableView).prefix(3)
        let allStillHidden = hiddenByUser.allSatisfy { $0.isHidden }
        #expect(allStillHidden)
    }

    @Test("A table with no laid-out viewport mounts everything rather than hiding it all")
    func noViewportMountsEverything() {
        let pool = DataGridColumnPool()
        let tableView = makeTableView()

        reconcileWide(pool, tableView: tableView, count: 120)

        let allMounted = dataColumns(in: tableView).allSatisfy { !$0.isHidden }
        #expect(allMounted)
    }

    /// Copy, Find, cell navigation and Size All Columns to Fit all ask "which columns is the user
    /// looking at". Answering that with isHidden narrows them to the mounted window, which silently
    /// drops the off-screen columns from a copied row and makes Find miss them entirely.
    @Test("Every column the result shows is presented, even when the window unmounts it")
    func unmountedColumnsAreStillPresented() {
        let pool = DataGridColumnPool()
        let (_, tableView) = makeScrolledTableView(viewportWidth: 800)

        reconcileWide(pool, tableView: tableView, count: 500)

        let columns = dataColumns(in: tableView)
        let presented = columns.filter { pool.presentsColumn($0) }
        let mounted = columns.filter { !$0.isHidden }

        #expect(presented.count == 500)
        #expect(mounted.count < presented.count)
    }

    @Test("A column the user hid is not presented")
    func userHiddenColumnIsNotPresented() {
        let pool = DataGridColumnPool()
        let (_, tableView) = makeScrolledTableView(viewportWidth: 800)

        reconcileWide(pool, tableView: tableView, count: 20, hidden: ["c3"])

        let presented = dataColumns(in: tableView).filter { pool.presentsColumn($0) }
        #expect(presented.count == 19)
        #expect(pool.hasUserHiddenColumns)
    }

    @Test("A surplus slot from a wider result is not presented")
    func surplusSlotIsNotPresented() {
        let pool = DataGridColumnPool()
        let (_, tableView) = makeScrolledTableView(viewportWidth: 800)

        reconcileWide(pool, tableView: tableView, count: 40)
        reconcileWide(pool, tableView: tableView, count: 5)

        let presented = dataColumns(in: tableView).filter { pool.presentsColumn($0) }
        #expect(presented.count == 5)
    }

    @Test("Detaching removes the spacers along with the pooled columns")
    func detachRemovesSpacers() {
        let pool = DataGridColumnPool()
        let (_, tableView) = makeScrolledTableView(viewportWidth: 800)

        reconcileWide(pool, tableView: tableView, count: 60)
        pool.detachFromTableView()

        let hasSpacer = tableView.tableColumns.contains(where: { ColumnIdentitySchema.isSpacer($0.identifier) })
        #expect(!hasSpacer)
    }
}
