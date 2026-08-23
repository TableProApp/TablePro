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
        // would silently rewrite the widths these tests assert on, and the default style and
        // intercell spacing put the columns at different document positions than the grid's, which
        // is the geometry the window is resolved against.
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.style = .plain
        tableView.intercellSpacing = NSSize(width: 1, height: 0)
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
        tableView.tableColumns.filter { $0.identifier != ColumnIdentitySchema.rowNumberIdentifier }
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

    @Test("A column the user hid is not presented")
    func userHiddenColumnIsNotPresented() {
        let pool = DataGridColumnPool()
        let tableView = makeTableView()

        reconcileWide(pool, tableView: tableView, count: 20, hidden: ["c3"])

        let presented = dataColumns(in: tableView).filter { pool.presentsColumn($0) }
        #expect(presented.count == 19)
        #expect(pool.hasUserHiddenColumns)
    }

    @Test("A surplus slot from a wider result is not presented")
    func surplusSlotIsNotPresented() {
        let pool = DataGridColumnPool()
        let tableView = makeTableView()

        reconcileWide(pool, tableView: tableView, count: 40)
        reconcileWide(pool, tableView: tableView, count: 5)

        let presented = dataColumns(in: tableView).filter { pool.presentsColumn($0) }
        #expect(presented.count == 5)
    }

    @Test("Detaching removes the pooled columns")
    func detachRemovesPooledColumns() {
        let pool = DataGridColumnPool()
        let tableView = makeTableView()

        reconcileWide(pool, tableView: tableView, count: 60)
        pool.detachFromTableView()

        #expect(dataColumns(in: tableView).isEmpty)
    }

    // MARK: - Window geometry while scrolling

    private func scroll(_ scrollView: NSScrollView, to offsetX: CGFloat, tableView: NSTableView) {
        scrollView.contentView.scroll(to: NSPoint(x: offsetX, y: scrollView.contentView.bounds.origin.y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        tableView.layoutSubtreeIfNeeded()
    }

    private func documentWidth(of tableView: NSTableView) -> CGFloat {
        tableView.layoutSubtreeIfNeeded()
        return tableView.frame.width
    }

    /// How much of the viewport, past the row-number column, no mounted data column paints into.
    ///
    /// Measured through `rect(ofColumn:)`, which is `NSTableView`'s own answer for where a column
    /// sits and is `NSZeroRect` for an unmounted one. Asking the resolver instead would only prove
    /// the resolver agrees with itself, which is exactly how #2381 shipped.
    private func unpaintedViewportWidth(in scrollView: NSScrollView, tableView: NSTableView) -> CGFloat {
        let viewport = scrollView.contentView.bounds
        let rowNumber = tableView.column(withIdentifier: ColumnIdentitySchema.rowNumberIdentifier)
        let contentStart = rowNumber >= 0
            ? max(viewport.minX, tableView.rect(ofColumn: rowNumber).maxX)
            : viewport.minX

        var painted: CGFloat = 0
        for column in dataColumns(in: tableView) where !column.isHidden {
            let index = tableView.column(withIdentifier: column.identifier)
            guard index >= 0 else { continue }
            let rect = tableView.rect(ofColumn: index)
            painted += max(0, min(rect.maxX, viewport.maxX) - max(rect.minX, contentStart))
        }
        return max(0, (viewport.maxX - contentStart) - painted)
    }

    private func mountedIdentifiers(in tableView: NSTableView) -> Set<NSUserInterfaceItemIdentifier> {
        Set(dataColumns(in: tableView).filter { !$0.isHidden }.map(\.identifier))
    }

    private func scrollOffsets(in scrollView: NSScrollView, tableView: NSTableView) -> [CGFloat] {
        let maximum = documentWidth(of: tableView) - scrollView.contentView.bounds.width
        guard maximum > 0 else { return [0] }
        let forward = Array(stride(from: 0, through: maximum, by: 150)) + [maximum]
        return forward + forward.reversed()
    }

    /// The reported bug. The window is resolved against a model of the whole column run, so the
    /// viewport has to be rebased into that model before it can pick a range. Counting the leading
    /// spacer as chrome subtracted the columns it stands in for a second time, and the window
    /// walked left while the reader scrolled right until it painted nothing at all.
    @Test("The mounted columns cover the viewport at every horizontal scroll offset")
    func windowCoversTheViewportWhileScrolling() {
        let pool = DataGridColumnPool()
        let (scrollView, tableView) = makeScrolledTableView(viewportWidth: 800)
        reconcileWide(pool, tableView: tableView, count: 100)

        var worstGap: CGFloat = 0
        for offset in scrollOffsets(in: scrollView, tableView: tableView) {
            scroll(scrollView, to: offset, tableView: tableView)
            pool.applyColumnWindow(in: tableView)
            tableView.layoutSubtreeIfNeeded()
            worstGap = max(worstGap, unpaintedViewportWidth(in: scrollView, tableView: tableView))
        }

        #expect(worstGap == 0)
    }

    /// A window that alternates between two ranges re-mounts columns on every scroll event, which
    /// is what the reader sees as flicker.
    @Test("Resolving again at the same scroll offset settles rather than alternating")
    func windowSettlesAtOneOffset() {
        let pool = DataGridColumnPool()
        let (scrollView, tableView) = makeScrolledTableView(viewportWidth: 800)
        reconcileWide(pool, tableView: tableView, count: 100)

        scroll(scrollView, to: documentWidth(of: tableView) / 2, tableView: tableView)
        pool.applyColumnWindow(in: tableView)
        tableView.layoutSubtreeIfNeeded()
        let settled = mountedIdentifiers(in: tableView)

        for _ in 0..<5 {
            pool.applyColumnWindow(in: tableView)
            tableView.layoutSubtreeIfNeeded()
        }

        #expect(mountedIdentifiers(in: tableView) == settled)
    }

    /// The spacers exist to keep the scroll extent, so no window position may change it.
    @Test("The document keeps its width at every window position")
    func documentWidthSurvivesEveryWindowPosition() {
        let pool = DataGridColumnPool()
        let (scrollView, tableView) = makeScrolledTableView(viewportWidth: 800)
        reconcileWide(pool, tableView: tableView, count: 100)
        let expected = documentWidth(of: tableView)

        for offset in scrollOffsets(in: scrollView, tableView: tableView) {
            scroll(scrollView, to: offset, tableView: tableView)
            pool.applyColumnWindow(in: tableView)
            #expect(documentWidth(of: tableView) == expected)
        }
    }

    @Test("Scrolled to the end, the last column is mounted")
    func lastColumnIsMountedAtTheEnd() throws {
        let pool = DataGridColumnPool()
        let (scrollView, tableView) = makeScrolledTableView(viewportWidth: 800)
        reconcileWide(pool, tableView: tableView, count: 100)

        scroll(
            scrollView,
            to: documentWidth(of: tableView) - scrollView.contentView.bounds.width,
            tableView: tableView
        )
        pool.applyColumnWindow(in: tableView)

        let last = try #require(dataColumns(in: tableView).last)
        #expect(!last.isHidden)
    }

    // MARK: - Reaching a column the window left out

    /// `rect(ofColumn:)` and `frameOfCell(atColumn:row:)` are both empty for an unmounted column,
    /// so Find scrolled to the document origin instead of the match and the inline editor opened
    /// nothing at all.
    @Test("A column the window left out can be mounted on demand")
    func mountColumnReachesAnUnmountedColumn() throws {
        let pool = DataGridColumnPool()
        let (scrollView, tableView) = makeScrolledTableView(viewportWidth: 800)
        reconcileWide(pool, tableView: tableView, count: 100)
        scroll(scrollView, to: 0, tableView: tableView)
        pool.applyColumnWindow(in: tableView)

        let last = try #require(dataColumns(in: tableView).last)
        #expect(last.isHidden)

        pool.mountColumn(last, in: tableView)
        tableView.layoutSubtreeIfNeeded()

        #expect(!last.isHidden)
        #expect(tableView.rect(ofColumn: tableView.column(withIdentifier: last.identifier)).width > 0)
    }

    /// Stretching the window out to reach a far column mounts every column in between, which is the
    /// cost the window exists to avoid: measured at 848ms and 3,081 cell views for one match 90
    /// columns away, and 4.8s at 500 columns.
    @Test("Mounting a far column does not mount everything in between")
    func mountColumnStaysBounded() throws {
        let pool = DataGridColumnPool()
        let (scrollView, tableView) = makeScrolledTableView(viewportWidth: 800)
        reconcileWide(pool, tableView: tableView, count: 100)
        scroll(scrollView, to: 0, tableView: tableView)
        pool.applyColumnWindow(in: tableView)
        let mountedBefore = mountedIdentifiers(in: tableView).count

        let last = try #require(dataColumns(in: tableView).last)
        pool.mountColumn(last, in: tableView)
        tableView.layoutSubtreeIfNeeded()

        #expect(!last.isHidden)
        #expect(mountedIdentifiers(in: tableView).count <= mountedBefore)
    }

    @Test("Mounting a far column keeps the document width")
    func mountColumnKeepsTheDocumentWidth() throws {
        let pool = DataGridColumnPool()
        let (scrollView, tableView) = makeScrolledTableView(viewportWidth: 800)
        reconcileWide(pool, tableView: tableView, count: 100)
        scroll(scrollView, to: 0, tableView: tableView)
        pool.applyColumnWindow(in: tableView)
        let expected = documentWidth(of: tableView)

        let last = try #require(dataColumns(in: tableView).last)
        pool.mountColumn(last, in: tableView)

        #expect(documentWidth(of: tableView) == expected)
    }

    @Test("A column the user hid is never mounted on demand")
    func mountColumnRefusesAUserHiddenColumn() throws {
        let pool = DataGridColumnPool()
        let (_, tableView) = makeScrolledTableView(viewportWidth: 800)
        reconcileWide(pool, tableView: tableView, count: 100, hidden: ["c99"])

        let hidden = try #require(dataColumns(in: tableView).last)
        pool.mountColumn(hidden, in: tableView)

        #expect(hidden.isHidden)
    }

    // MARK: - Naming the ends of the data run

    /// The window's spacers are attached columns too, and the leading one sits immediately before
    /// the first data column, so a fixed position names a spacer rather than data.
    @Test("The first and last presented columns are data columns, not spacers")
    func presentedEndsSkipTheSpacers() throws {
        let pool = DataGridColumnPool()
        let (_, tableView) = makeScrolledTableView(viewportWidth: 800)
        reconcileWide(pool, tableView: tableView, count: 100)

        let first = try #require(pool.firstPresentedColumnIndex(in: tableView))
        let last = try #require(pool.lastPresentedColumnIndex(in: tableView))

        #expect(!ColumnIdentitySchema.isSpacer(tableView.tableColumns[first].identifier))
        #expect(!ColumnIdentitySchema.isSpacer(tableView.tableColumns[last].identifier))
        #expect(tableView.tableColumns[first].identifier == dataColumns(in: tableView).first?.identifier)
        #expect(tableView.tableColumns[last].identifier == dataColumns(in: tableView).last?.identifier)
    }

    @Test("Walking forward and back from an end stays inside the data run")
    func presentedNeighboursStayInsideTheDataRun() throws {
        let pool = DataGridColumnPool()
        let (_, tableView) = makeScrolledTableView(viewportWidth: 800)
        reconcileWide(pool, tableView: tableView, count: 20)

        let first = try #require(pool.firstPresentedColumnIndex(in: tableView))
        let last = try #require(pool.lastPresentedColumnIndex(in: tableView))

        #expect(pool.previousPresentedColumnIndex(before: first, in: tableView) == nil)
        #expect(pool.nextPresentedColumnIndex(after: last, in: tableView) == nil)
        #expect(pool.nextPresentedColumnIndex(after: first, in: tableView) != nil)
        #expect(pool.previousPresentedColumnIndex(before: last, in: tableView) != nil)
    }

    /// The create-table grid opens with no columns at all, where every attached column is chrome.
    @Test("A result with no columns presents no column at either end")
    func emptyResultHasNoPresentedEnds() {
        let pool = DataGridColumnPool()
        let (_, tableView) = makeScrolledTableView(viewportWidth: 800)

        reconcileWide(pool, tableView: tableView, count: 0)

        #expect(pool.firstPresentedColumnIndex(in: tableView) == nil)
        #expect(pool.lastPresentedColumnIndex(in: tableView) == nil)
    }

    @Test("A single-column result presents that column at both ends")
    func singleColumnResultHasOneEnd() {
        let pool = DataGridColumnPool()
        let (_, tableView) = makeScrolledTableView(viewportWidth: 800)

        reconcileWide(pool, tableView: tableView, count: 1)

        #expect(pool.firstPresentedColumnIndex(in: tableView) == pool.lastPresentedColumnIndex(in: tableView))
        #expect(pool.firstPresentedColumnIndex(in: tableView) != nil)
    }

    /// Size All Columns to Fit reaches the columns the window unmounted as well, so the spacers
    /// stand in at the width those columns used to have and the document ends up short.
    @Test("Resizing unmounted columns restores the full document width")
    func widthChangeOutsideTheWindowRestoresDocumentWidth() {
        let pool = DataGridColumnPool()
        let (scrollView, tableView) = makeScrolledTableView(viewportWidth: 800)
        reconcileWide(pool, tableView: tableView, count: 100)
        scroll(scrollView, to: 0, tableView: tableView)
        pool.applyColumnWindow(in: tableView)

        for column in dataColumns(in: tableView) {
            column.width = 300
        }
        pool.invalidateColumnWindow()
        pool.applyColumnWindow(in: tableView)

        let gap = tableView.intercellSpacing.width
        let everyColumnSlot = dataColumns(in: tableView).reduce(0) { $0 + $1.width + gap }
        let occupied = tableView.tableColumns
            .filter { !$0.isHidden && $0.identifier != ColumnIdentitySchema.rowNumberIdentifier }
            .reduce(0) { $0 + $1.width + gap }

        #expect(occupied == everyColumnSlot)
    }
}
