import AppKit
import Combine
import TableProPluginKit
import TableProTheme

@MainActor
protocol DataGridMountedView: AnyObject {
    func apply(_ change: DataGridChange)
    func selectionDidChange()
    func configurationDidChange()
    func reveal(row: Int, displayColumn: Int?)
    func revealColumn(_ displayColumn: Int)
    func sortDidChange()
    func summaryRulesDidChange()
    func viewportSample() -> (row: Int, offset: CGFloat)?
    @discardableResult func beginEditing(row: Int, displayColumn: Int) -> Bool
    var isEditing: Bool { get }
    func commitEditing() -> Bool
    func discardEditing()
    @discardableResult func focus() -> Bool
    // Where a popover about a column (statistics, value filter) points.
    func anchor(forColumn displayColumn: Int) -> (view: NSView, rect: NSRect)?
}

@MainActor
final class DataGridModel: ObservableObject {
    let id = UUID()
    weak var dataSource: (any DataGridDataSource)?
    weak var actions: (any DataGridActions)?
    let store: any DataGridStateStore
    let display = DataGridDisplayState()
    let find = GridFindState()
    let selectionSummary: SelectionSummaryState?

    var configuration: DataGridConfiguration {
        didSet {
            guard configuration != oldValue else { return }
            mountedView?.configurationDidChange()
            editabilityRevision &+= 1
        }
    }

    var themeScope: ThemeScope {
        didSet { mountedView?.configurationDidChange() }
    }

    private(set) var columns: DataGridColumnSet = .empty
    private(set) var order: DataGridRowOrder = .unfiltered
    private(set) var selection: GridSelection = .empty

    @Published private(set) var displayRevision = 0
    @Published private(set) var selectionRevision = 0
    @Published private(set) var editabilityRevision = 0
    // What a fitsRows grid needs to show every row; the mounted view measures it.
    @Published private(set) var fittingHeight: CGFloat = 0

    private(set) weak var mountedView: (any DataGridMountedView)?
    private var orderRevision = 0

    private let schemaRegistry: SchemaRegistryCache
    private var schemaObservers: Set<AnyCancellable> = []
    private var staleSchemaColumns: Set<Int> = []

    init(
        store: any DataGridStateStore = InMemoryDataGridStateStore(),
        configuration: DataGridConfiguration = DataGridConfiguration(),
        themeScope: ThemeScope = .live,
        selectionSummary: SelectionSummaryState? = nil,
        schemaRegistry: SchemaRegistryCache = .shared
    ) {
        self.store = store
        self.configuration = configuration
        self.themeScope = themeScope
        self.selectionSummary = selectionSummary
        self.schemaRegistry = schemaRegistry
        observeSchemas()
    }

    // MARK: - Rows

    var rows: TableRows { dataSource?.gridRows ?? TableRows() }
    var changeState: AnyChangeManager? { dataSource?.gridChangeState }
    var rowCount: Int { order.count(in: rows) }

    func rowID(at displayIndex: Int) -> RowID? {
        order.rowID(at: displayIndex, in: rows)
    }

    func row(at displayIndex: Int) -> Row? {
        order.row(at: displayIndex, in: rows)
    }

    func displayIndex(of rowID: RowID) -> Int? {
        order.displayIndex(of: rowID, in: rows)
    }

    func reloadRows() {
        let current = rows
        store.valueFilter = store.valueFilter.remapped(toColumns: current.columns)
        let rebuilt = DataGridColumnSet(tableRows: current, layout: store.columnLayout)
        if rebuilt != columns {
            columns = rebuilt
            mountedView?.apply(.columnsChanged)
        }
        order = resolveOrder(in: current)
        display.cache.removeAll()
        restoreSelection(in: current)
        displayRevision &+= 1
        mountedView?.apply(.reload)
        refreshFind()
        prefetchSchemas(in: current, storageRows: nil, retryingFailures: true)
    }

    func apply(_ delta: Delta) {
        if delta == .fullReplace {
            reloadRows()
            return
        }
        let current = rows
        if delta.changesRowSet || delta == .columnsReplaced {
            if delta == .columnsReplaced {
                columns = DataGridColumnSet(tableRows: current, layout: store.columnLayout)
            }
            let previous = order
            order = resolveOrder(in: current)
            let change = DataGridChange.from(delta, order: previous, rows: current, columns: columns)
            if change == .reload || change == .columnsChanged {
                display.cache.removeAll()
            }
            restoreSelection(in: current)
            displayRevision &+= 1
            mountedView?.apply(change)
            refreshFind()
            if case .rowsInserted(let inserted) = delta {
                prefetchSchemas(in: current, storageRows: inserted, retryingFailures: false)
            } else if delta == .columnsReplaced {
                prefetchSchemas(in: current, storageRows: nil, retryingFailures: false)
            }
            return
        }
        switch delta {
        case .cellChanged(let row, _):
            prefetchSchemas(in: current, storageRows: IndexSet(integer: row), retryingFailures: false)
        case .cellsChanged(let positions):
            prefetchSchemas(in: current, storageRows: IndexSet(positions.map(\.row)), retryingFailures: false)
        default:
            break
        }
        let change = DataGridChange.from(delta, order: order, rows: current, columns: columns)
        guard !change.isNone else { return }
        if case .rowsUpdated(let displayRows, _) = change {
            for displayRow in displayRows {
                if let id = order.rowID(at: displayRow, in: current) {
                    display.cache.clearValues(forID: id)
                }
            }
        }
        // An edited row stays where the filter put it until the filter or the row set changes (#2667).
        mountedView?.apply(change)
        refreshFind()
    }

    private func resolveOrder(in rows: TableRows) -> DataGridRowOrder {
        let ids = GridDisplayOrderResolver.resolve(
            tableRows: rows,
            valueFilter: store.valueFilter,
            displayFormats: store.displayFormats,
            databaseType: configuration.traits.databaseType
        )
        orderRevision &+= 1
        return DataGridRowOrder(filteredIDs: ids, revision: orderRevision)
    }

    // MARK: - Selection

    var selectedRowIDs: [RowID] {
        order.rowIDs(atDisplayIndexes: selection.affectedRows, in: rows)
    }

    var activeCell: (rowID: RowID, column: DataGridColumn)? {
        guard let active = selection.activeCell,
              let rowID = order.rowID(at: active.row, in: rows),
              let column = columns.column(at: active.displayColumn) else { return nil }
        return (rowID, column)
    }

    func setSelection(_ newSelection: GridSelection) {
        let clamped = newSelection.clamped(rowLimit: rowCount, columnLimit: columns.count)
        guard clamped != selection else { return }
        selection = clamped
        store.selectionSnapshot = GridSelectionSnapshot(clamped, order: order, rows: rows, columns: columns)
        selectionRevision &+= 1
        mountedView?.selectionDidChange()
    }

    // Selects the cell's row and puts the cursor on the cell, which is what a click does.
    func selectCell(_ cell: GridCoord) {
        setSelection(GridSelectionReducer.cursor(cell, in: GridSelectionContext(rowCount: rowCount, columnCount: columns.count)))
    }

    func selectRows(_ rowIDs: [RowID]) {
        let current = rows
        var rects: [GridRect] = []
        let lastColumn = max(columns.count - 1, 0)
        for range in order.displayIndexes(of: rowIDs, in: current).rangeView {
            rects.append(GridRect(rows: range.lowerBound...(range.upperBound - 1), columns: 0...lastColumn))
        }
        let active = rects.first.map { GridCoord(row: $0.rows.lowerBound, displayColumn: selection.activeCell?.displayColumn ?? 0) }
        setSelection(GridSelection(rectangles: rects, activeCell: active, anchor: active, mode: rects.isEmpty ? .cells : .rows))
    }

    func clearSelection() {
        setSelection(.empty)
    }

    // The change that follows tells the view: a selection moved ahead of it would end an open edit.
    private func restoreSelection(in rows: TableRows) {
        let resolved = store.selectionSnapshot
            .resolved(order: order, rows: rows, columns: columns)
            .clamped(rowLimit: order.count(in: rows), columnLimit: columns.count)
        guard resolved != selection else { return }
        selection = resolved
        selectionRevision &+= 1
    }

    // MARK: - View state

    func setSort(_ sort: SortState) {
        guard sort != store.sortState else { return }
        store.sortState = sort
        actions?.gridSortDidChange(sort)
        mountedView?.sortDidChange()
    }

    // An owner changed or declined a sort outside the header; the header re-reads it.
    func sortStateDidChange() {
        mountedView?.sortDidChange()
    }

    func setValueFilter(_ filter: GridValueFilterState) {
        guard filter != store.valueFilter else { return }
        guard let actions else {
            applyValueFilter(filter)
            return
        }
        actions.gridConfirmDisplayOrderChange { [weak self] in
            self?.applyValueFilter(filter)
        }
    }

    private func applyValueFilter(_ filter: GridValueFilterState) {
        store.valueFilter = filter
        let current = rows
        order = resolveOrder(in: current)
        restoreSelection(in: current)
        displayRevision &+= 1
        mountedView?.apply(.reload)
        refreshFind()
    }

    func updateColumnLayout(_ mutate: (inout ColumnLayoutState) -> Void) {
        var layout = store.columnLayout
        mutate(&layout)
        guard layout != store.columnLayout else { return }
        store.columnLayout = layout
        let current = rows
        let rebuilt = DataGridColumnSet(tableRows: current, layout: layout)
        if rebuilt != columns {
            let snapshot = store.selectionSnapshot
            columns = rebuilt
            selection = snapshot.resolved(order: order, rows: current, columns: rebuilt)
                .clamped(rowLimit: rowCount, columnLimit: rebuilt.count)
            selectionRevision &+= 1
            mountedView?.apply(.columnsChanged)
            mountedView?.selectionDidChange()
            refreshFind()
        } else {
            mountedView?.apply(.columnsChanged)
        }
    }

    func setDisplayFormat(_ format: ValueDisplayFormat?, for column: DataGridColumn) {
        let current = rows
        let previous = displayFormat(for: column)
        guard previous != format else { return }
        let formats = DisplayFormatArray.setting(
            format, at: column.dataIndex, in: store.displayFormats, columnCount: current.columns.count
        )
        // A filter stores the shown text, so the values the user picked follow the new format.
        if let remapped = remappedValueFilter(column: column, from: previous, to: format, in: current) {
            store.valueFilter = remapped
        }
        store.displayFormats = formats
        redrawFormatted([column], in: current)
        prefetchSchemas(in: current, storageRows: nil, retryingFailures: true)
    }

    private func redrawFormatted(_ changed: [DataGridColumn], in current: TableRows) {
        display.cache.clearValues(forDataIndexes: Set(changed.map(\.dataIndex)))
        if changed.contains(where: { store.valueFilter.filter(forColumn: $0.dataIndex) != nil }) {
            order = resolveOrder(in: current)
            restoreSelection(in: current)
            displayRevision &+= 1
            mountedView?.apply(.reload)
        } else {
            let positions = IndexSet(changed.compactMap { columns.displayPosition(of: $0.id) })
            if !positions.isEmpty {
                mountedView?.apply(.rowsUpdated(IndexSet(0..<rowCount), columns: positions))
            }
        }
        refreshFind()
    }

    // MARK: - Schemas

    private func observeSchemas() {
        let center = NotificationCenter.default
        center.publisher(for: SchemaRegistryCache.didChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let connectionID = notification.userInfo?[SchemaRegistryCache.connectionIDKey] as? UUID else { return }
                MainActor.assumeIsolated {
                    self?.schemasDidChange { $0 == .schemaRegistry(connectionID: connectionID) }
                }
            }
            .store(in: &schemaObservers)
        center.publisher(for: AvroSchemaStore.didRestoreSchema)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let schemaID = notification.userInfo?[AvroSchemaStore.schemaIDKey] as? String else { return }
                MainActor.assumeIsolated {
                    self?.schemasDidChange { $0 == .avro(schemaID: schemaID) }
                }
            }
            .store(in: &schemaObservers)
        center.publisher(for: ProtobufSchemaStore.didRestoreSchema)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let schemaID = notification.userInfo?[ProtobufSchemaStore.schemaIDKey] as? String else { return }
                MainActor.assumeIsolated {
                    self?.schemasDidChange {
                        if case .protobufSchema(schemaID, _) = $0 { return true }
                        return false
                    }
                }
            }
            .store(in: &schemaObservers)
    }

    // Coalesced to one redraw per run loop turn, since a page of values can name many schemas.
    func schemasDidChange(matching matches: (ValueDisplayFormat) -> Bool) {
        let wasEmpty = staleSchemaColumns.isEmpty
        for (dataIndex, format) in store.displayFormats.enumerated() {
            if let format, matches(format) { staleSchemaColumns.insert(dataIndex) }
        }
        guard wasEmpty, !staleSchemaColumns.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.redrawStaleSchemaColumns() }
        }
    }

    private func redrawStaleSchemaColumns() {
        let stale = staleSchemaColumns
        staleSchemaColumns = []
        let changed = columns.columns.filter { stale.contains($0.dataIndex) }
        guard !changed.isEmpty else { return }
        let current = rows
        // The format is the same, but the values move from the stored bytes to decoded text, and a filter has to follow.
        for column in changed {
            if let remapped = remappedValueFilter(column: column, from: nil, to: displayFormat(for: column), in: current) {
                store.valueFilter = remapped
            }
        }
        redrawFormatted(changed, in: current)
    }

    private func prefetchSchemas(in current: TableRows, storageRows: IndexSet?, retryingFailures: Bool) {
        let databaseType = configuration.traits.databaseType
        var wanted: [UUID: Set<UInt32>] = [:]
        for (dataIndex, format) in store.displayFormats.enumerated() {
            guard case .schemaRegistry(let connectionID)? = format else { continue }
            let type = dataIndex < current.columnTypes.count ? current.columnTypes[dataIndex] : nil
            guard format?.isApplicable(to: type, databaseType: databaseType) == true else { continue }
            let holdsBytes = BinaryValueBytes.holdsBytes(columnType: type)
            var ids = wanted[connectionID, default: []]
            func collect(_ row: Row) {
                guard dataIndex < row.values.count,
                      let id = Self.schemaID(of: row.values[dataIndex], holdsBytes: holdsBytes) else { return }
                ids.insert(id)
            }
            if let storageRows {
                for index in storageRows where index < current.rows.count { collect(current.rows[index]) }
            } else {
                for row in current.rows { collect(row) }
            }
            wanted[connectionID] = ids
        }
        for (connectionID, ids) in wanted {
            schemaRegistry.prefetch(connectionID: connectionID, schemaIDs: ids, retryingFailures: retryingFailures)
        }
    }

    private static func schemaID(of value: PluginCellValue, holdsBytes: Bool) -> UInt32? {
        switch value {
        case .null:
            return nil
        case .bytes(let data):
            return SchemaRegistryFrame.schemaID(prefix: data)
        case .text(let text):
            let head = String(String.UnicodeScalarView(text.unicodeScalars.prefix(SchemaRegistryFrame.headerLength)))
            return BinaryValueBytes.data(of: head, holdsBytes: holdsBytes).flatMap { SchemaRegistryFrame.schemaID(prefix: $0) }
        }
    }

    private func remappedValueFilter(
        column: DataGridColumn,
        from oldFormat: ValueDisplayFormat?,
        to newFormat: ValueDisplayFormat?,
        in rows: TableRows
    ) -> GridValueFilterState? {
        let dataIndex = column.dataIndex
        guard let existing = store.valueFilter.filter(forColumn: dataIndex) else { return nil }
        let databaseType = configuration.traits.databaseType
        var removed = Set<String>()
        var added = Set<String>()
        for row in rows.rows where dataIndex < row.values.count {
            let raw = row.values[dataIndex]
            guard raw != .null else { continue }
            let old = GridDisplayOrderResolver.displayValue(
                raw, columnType: column.type, displayFormat: oldFormat, databaseType: databaseType
            )
            guard existing.selectedValues.contains(old) else { continue }
            let new = GridDisplayOrderResolver.displayValue(
                raw, columnType: column.type, displayFormat: newFormat, databaseType: databaseType
            )
            if old != new {
                removed.insert(old)
                added.insert(new)
            }
        }
        var selected = existing.selectedValues
        selected.subtract(removed)
        selected.formUnion(added)
        guard selected != existing.selectedValues else { return nil }
        var filter = store.valueFilter
        filter.set(
            ColumnValueFilter(selectedValues: selected, includesNull: existing.includesNull),
            columnName: column.name,
            forColumn: dataIndex
        )
        return filter
    }

    func displayFormat(for column: DataGridColumn) -> ValueDisplayFormat? {
        let formats = store.displayFormats
        return column.dataIndex < formats.count ? formats[column.dataIndex] : nil
    }

    // MARK: - Editing

    func isColumnWritable(_ column: DataGridColumn) -> Bool {
        guard configuration.isEditable else { return false }
        let name = column.name
        if configuration.lockedColumns.contains(name) { return false }
        if configuration.traits.immutableColumns.contains(name) { return false }
        if changeState?.generatedColumns.contains(name) == true { return false }
        return true
    }

    var isEditing: Bool { mountedView?.isEditing ?? false }

    // Owners that deferred work while an editor was open resume here.
    var onEditingEnded: (@MainActor () -> Void)?

    func editingDidEnd() {
        onEditingEnded?()
    }

    @discardableResult
    func beginEditing(rowID: RowID, columnID: DataGridColumnID) -> Bool {
        guard let row = displayIndex(of: rowID), let column = columns.displayPosition(of: columnID) else { return false }
        return mountedView?.beginEditing(row: row, displayColumn: column) ?? false
    }

    // Owners call this before anything that repoints or replaces what an edit was made against.
    @discardableResult
    func commitEditing() -> Bool {
        mountedView?.commitEditing() ?? true
    }

    func discardEditing() {
        mountedView?.discardEditing()
    }

    @discardableResult
    func commit(_ edits: [DataGridCellEdit], actionName: String) -> Bool {
        guard let actions else { return false }
        let current = rows
        let resolved = edits.compactMap { resolve($0, in: current) }
        guard !resolved.isEmpty else { return false }
        return actions.gridCommit(resolved, actionName: actionName)
    }

    private func resolve(_ edit: DataGridCellEdit, in rows: TableRows) -> DataGridResolvedEdit? {
        guard let column = columns.column(id: edit.columnID) ?? columnOutsidePresentation(edit.columnID, in: rows),
              isColumnWritable(column),
              let storageIndex = rows.index(of: edit.rowID) else { return nil }
        let row = rows.rows[storageIndex]
        let dataIndex = column.dataIndex
        guard dataIndex < row.values.count, changeState?.isRowDeleted(edit.rowID) != true else { return nil }
        guard row.unloadedByteCount(dataIndex) == nil else { return nil }

        let newValue: PluginCellValue
        let isExpression: Bool
        var removesField = false
        switch edit.value {
        case .enteredText(let text):
            if let text,
               let databaseType = configuration.traits.databaseType,
               let typed = CellEntry.typed(
                   text,
                   columnType: rows.editingColumnType(at: dataIndex),
                   databaseType: databaseType,
                   writer: configuration.traits.cellWriterSupport
               ) {
                newValue = typed.value
                isExpression = typed.isExpression
            } else if let entered = rows.enteredValue(text, forColumn: dataIndex) {
                newValue = entered
                isExpression = false
            } else {
                return nil
            }
        case .value(let value, let expression):
            newValue = value
            isExpression = expression
        case .removeField:
            guard configuration.traits.supportsFieldRemoval else { return nil }
            newValue = .null
            isExpression = false
            removesField = true
        }

        let oldValue = row.values[dataIndex]
        let absence = FieldAbsence(
            wasAbsent: row.isAbsent(dataIndex),
            isAbsent: removesField,
            originalRow: row.absentColumns
        )
        let wasExpression = changeState?.isExpression(rowID: row.id, columnIndex: dataIndex) ?? false
        guard oldValue != newValue || absence.wasAbsent != absence.isAbsent || wasExpression != isExpression else {
            return nil
        }
        return DataGridResolvedEdit(
            rowID: row.id,
            dataIndex: dataIndex,
            columnName: column.name,
            oldValue: oldValue,
            newValue: newValue,
            originalRow: Array(row.values),
            absence: absence,
            isExpression: isExpression
        )
    }

    // An owner-built edit can target a column the user hid.
    private func columnOutsidePresentation(_ id: DataGridColumnID, in rows: TableRows) -> DataGridColumn? {
        let ids = DataGridColumnSet.columnIDs(for: rows.columns)
        guard let dataIndex = ids.firstIndex(of: id) else { return nil }
        return DataGridColumn(
            id: id,
            dataIndex: dataIndex,
            type: dataIndex < rows.columnTypes.count ? rows.columnTypes[dataIndex] : nil,
            comment: rows.columnComments[id.name]
        )
    }

    // MARK: - Mounting

    func attach(_ view: any DataGridMountedView) {
        mountedView = view
    }

    func detach(_ view: any DataGridMountedView) {
        guard mountedView === view else { return }
        mountedView = nil
    }

    var isMounted: Bool { mountedView != nil }

    func setFittingHeight(_ height: CGFloat) {
        guard height != fittingHeight else { return }
        fittingHeight = height
    }

    func revealColumn(_ id: DataGridColumnID) {
        guard let position = columns.displayPosition(of: id) else { return }
        mountedView?.revealColumn(position)
    }

    func viewportSample() -> (row: Int, offset: CGFloat)? {
        mountedView?.viewportSample()
    }

    // A pending-change mark or a tint changed with no value under it.
    func repaintRows(_ rowIDs: some Sequence<RowID>) {
        guard let mountedView else { return }
        let indexes = order.displayIndexes(of: rowIDs, in: rows)
        guard !indexes.isEmpty else { return }
        mountedView.apply(.rowsUpdated(indexes, columns: nil))
    }

    // A column's summary rule moved with no value under it, so only the selection summary is computed again.
    func summaryRulesDidChange() {
        mountedView?.summaryRulesDidChange()
    }

    func repaintAllRows() {
        guard let mountedView, rowCount > 0 else { return }
        mountedView.apply(.rowsUpdated(IndexSet(integersIn: 0..<rowCount), columns: nil))
    }

    func anchor(for column: DataGridColumn) -> (view: NSView, rect: NSRect)? {
        guard let position = columns.displayPosition(of: column.id) else { return nil }
        return mountedView?.anchor(forColumn: position)
    }

    func reveal(rowID: RowID, columnID: DataGridColumnID? = nil) {
        guard let row = displayIndex(of: rowID) else { return }
        mountedView?.reveal(row: row, displayColumn: columnID.flatMap { columns.displayPosition(of: $0) })
    }

    @discardableResult
    func focus() -> Bool {
        mountedView?.focus() ?? false
    }
}
