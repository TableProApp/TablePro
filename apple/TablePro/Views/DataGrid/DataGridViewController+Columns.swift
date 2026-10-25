//
//  DataGridViewController+Columns.swift
//  TablePro
//

import AppKit

extension DataGridViewController {
    // Builds both panes' column lists from the model. Never culls a column with isHidden: each write costs
    // O(attached columns), and seconds at 500 columns with mounted views (probe section 5).
    func reconcileColumns(widening changedPresentations: IndexSet = []) {
        isRebuildingColumns = true
        defer { isRebuildingColumns = false }

        let columns = model.columns
        let ids = Set(columns.columns.map(\.id))
        // A new result measures every column again; hiding, showing, moving or freezing keeps the widths the reader sees.
        let rows = model.rows
        let resultIDs = DataGridColumnSet.columnIDs(for: rows.columns)
        // Widths measured over a result whose rows had not landed yet were the headings' alone.
        if resultIDs != resultColumnIDs || (!rows.rows.isEmpty && !knownWidthsSawRows) {
            resultColumnIDs = resultIDs
            knownWidths.removeAll()
            savedWidthIDs.removeAll()
        }
        knownWidthsSawRows = !rows.rows.isEmpty
        let layout = model.store.columnLayout
        let calculator = widthCalculator()
        var desired: [NSTableColumn] = []
        if model.configuration.showRowNumbers {
            desired.append(main.pooledRowNumberColumn())
        }
        var nextSaved = Set<DataGridColumnID>()
        for column in columns.columns {
            let tableColumn = main.pooledColumn(for: column.id)
            let width: CGFloat
            if let saved = layout.columnWidths[column.name], keepsSavedWidth(of: column, in: layout) {
                width = saved
                nextSaved.insert(column.id)
            } else if let known = knownWidths[column.id], !savedWidthIDs.contains(column.id) {
                // Metadata that reveals an accessory arrives after the rows; an auto width only grows to fit it.
                width = changedPresentations.contains(column.dataIndex)
                    ? max(known, calculator.automaticWidth(widthInput(for: column)))
                    : known
            } else {
                width = calculator.automaticWidth(widthInput(for: column))
            }
            configure(tableColumn, as: column, width: width)
            knownWidths[column.id] = tableColumn.width
            desired.append(tableColumn)
        }
        apply(desired, to: main)
        main.forgetColumns(except: ids)
        savedWidthIDs = nextSaved
        updateFrozenPane()
        refreshHeaders()
    }

    // A width saved before accessories reserved room, and never set by the user, is measured again.
    private func keepsSavedWidth(of column: DataGridColumn, in layout: ColumnLayoutState) -> Bool {
        if layout.columnContentWidths?[column.name] != nil { return true }
        return presenter.presentation(forDataIndex: column.dataIndex).accessory == .none
    }

    // The frozen pane shows the row numbers and the frozen columns that fit in two thirds of the grid.
    func updateFrozenPane() {
        let wasRebuilding = isRebuildingColumns
        isRebuildingColumns = true
        defer { isRebuildingColumns = wasRebuilding }

        sizeRowNumberColumns()
        let count = resolveEffectiveFrozenCount()
        effectiveFrozenCount = count
        let frozenColumns = Array(model.columns.columns.prefix(count))
        var desired: [NSTableColumn] = []
        if model.configuration.showRowNumbers {
            desired.append(frozen.pooledRowNumberColumn())
        }
        for column in frozenColumns {
            let tableColumn = frozen.pooledColumn(for: column.id)
            configure(tableColumn, as: column, width: main.tableColumn(for: column.id)?.width ?? DataGridMetrics.dataColumnMinWidth)
            desired.append(tableColumn)
        }
        apply(desired, to: frozen)
        frozen.forgetColumns(except: Set(frozenColumns.map(\.id)))
        applyRowNumberWidth()
        container.frozenPaneWidth = desired.isEmpty ? 0 : frozen.columnsWidth
    }

    func resolveEffectiveFrozenCount() -> Int {
        let requested = model.columns.frozenCount
        guard requested > 0 else { return 0 }
        let available = container.bounds.width * DataGridMetrics.maximumFrozenShare
        let spacing = main.tableView.intercellSpacing.width
        var width = main.rowNumberTableColumn.map { $0.width + spacing } ?? 0
        var count = 0
        for column in model.columns.frozenColumns {
            guard let tableColumn = main.tableColumn(for: column.id) else { break }
            let next = width + tableColumn.width + spacing
            guard next <= available else { break }
            width = next
            count += 1
        }
        return count
    }

    // Freeze Up to This Column is refused when the frozen run would leave less than a third of the grid to scroll.
    func canFreezeColumns(throughDisplayPosition position: Int) -> Bool {
        guard let index = main.tableIndex(forDisplayPosition: position, columns: model.columns) else { return false }
        let width = main.tableView.rect(ofColumn: index).maxX
        let available = container.bounds.width * DataGridMetrics.maximumFrozenShare
        return available > 0 && width <= available
    }

    private func apply(_ desired: [NSTableColumn], to pane: DataGridPane) {
        let table = pane.tableView
        let wanted = Set(desired.map(\.identifier))
        for column in table.tableColumns where !wanted.contains(column.identifier) {
            table.removeTableColumn(column)
        }
        let attached = Set(table.tableColumns.map(\.identifier))
        for column in desired where !attached.contains(column.identifier) {
            table.addTableColumn(column)
        }

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        defer { NSAnimationContext.endGrouping() }

        var indexByIdentifier: [NSUserInterfaceItemIdentifier: Int] = [:]
        indexByIdentifier.reserveCapacity(table.tableColumns.count)
        for (index, column) in table.tableColumns.enumerated() {
            indexByIdentifier[column.identifier] = index
        }
        for (target, column) in desired.enumerated() {
            guard let current = indexByIdentifier[column.identifier], current != target else { continue }
            table.moveColumn(current, toColumn: target)
            Self.shiftIndexes(&indexByIdentifier, from: current, to: target)
        }
        pane.invalidateSlots()
    }

    private static func shiftIndexes(_ map: inout [NSUserInterfaceItemIdentifier: Int], from source: Int, to destination: Int) {
        let lower = min(source, destination)
        let upper = max(source, destination)
        let delta = source < destination ? -1 : 1
        for (key, value) in map where value >= lower && value <= upper {
            map[key] = value == source ? destination : value + delta
        }
    }

    // Raising minWidth past width moves the width without updating the table's geometry, so the width goes in first.
    private func configure(_ tableColumn: NSTableColumn, as column: DataGridColumn, width: CGFloat) {
        let configuration = model.configuration
        let minWidth = configuration.columnMinimumWidths[column.name] ?? DataGridMetrics.dataColumnMinWidth
        let resolvedWidth = max(width, minWidth)
        if tableColumn.minWidth > minWidth {
            tableColumn.minWidth = minWidth
        }
        if tableColumn.width != resolvedWidth {
            tableColumn.width = resolvedWidth
        }
        if tableColumn.minWidth != minWidth {
            tableColumn.minWidth = minWidth
        }
        if tableColumn.isEditable != configuration.isEditable {
            tableColumn.isEditable = configuration.isEditable
        }
        guard configuration.supportsColumnSort else {
            if tableColumn.sortDescriptorPrototype != nil {
                tableColumn.sortDescriptorPrototype = nil
            }
            return
        }
        let ascending = firstClickSortDirection == .ascending
        let key = column.id.stringValue
        if tableColumn.sortDescriptorPrototype?.key != key || tableColumn.sortDescriptorPrototype?.ascending != ascending {
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: ascending)
        }
    }

    // The column is pinned to one width, so its interval opens before the width moves through it; AppKit
    // otherwise keeps the old geometry and posts no resize (measured on macOS 27).
    func applyRowNumberWidth() {
        guard sizeRowNumberColumns() else { return }
        container.frozenPaneWidth = frozen.tableView.tableColumns.isEmpty ? 0 : frozen.columnsWidth
        redrawVisibleRows()
    }

    @discardableResult
    private func sizeRowNumberColumns() -> Bool {
        let maxNumber = max((model.dataSource?.gridRowNumberOffset ?? 0) + model.rowCount, 1)
        let font = ThemeEngine.shared.dataGridFonts.rowNumber
        let textWidth = (String(maxNumber) as NSString).size(withAttributes: [.font: font]).width
        let measured = ceil(textWidth) + 2 * DataGridMetrics.cellHorizontalInset + DataGridMetrics.rowNumberHeaderPadding
        let width = max(DataGridMetrics.rowNumberColumnMinWidth, measured)
        var changed = false
        for pane in panes {
            guard let column = pane.rowNumberTableColumn,
                  column.width != width || column.minWidth != width || column.maxWidth != width else { continue }
            column.minWidth = min(column.minWidth, width)
            column.maxWidth = max(column.maxWidth, width)
            column.width = width
            column.minWidth = width
            column.maxWidth = width
            changed = true
        }
        return changed
    }

    var firstClickSortDirection: SortDirection {
        guard model.configuration.appliesRowSortPreferences else { return .ascending }
        return AppSettingsManager.shared.dataGrid.defaultSortDirection
    }

    // MARK: - Width measurement

    func widthCalculator() -> DataGridColumnWidthCalculator {
        DataGridColumnWidthCalculator(
            rows: model.rows,
            databaseType: model.configuration.traits.databaseType,
            nullDisplayString: presenter.registry.nullDisplayString,
            revealsInvisibleCharacters: presenter.registry.showsInvisibleCharacters,
            fonts: ThemeEngine.shared.dataGridFonts
        )
    }

    func widthInput(for column: DataGridColumn) -> DataGridColumnWidthCalculator.Input {
        DataGridColumnWidthCalculator.Input(
            column: column,
            accessory: presenter.presentation(forDataIndex: column.dataIndex).accessory,
            displayFormat: model.displayFormat(for: column)
        )
    }

    private var visibleGridWidth: CGFloat {
        main.scrollView.contentView.bounds.width
    }

    func fittedWidth(for column: DataGridColumn, fittedColumnCount: Int = 1) -> CGFloat {
        widthCalculator().fittedWidth(widthInput(for: column), availableWidth: visibleGridWidth, fittedColumnCount: fittedColumnCount)
    }

    // Size to Fit, from the loaded display strings; written to the model as a width the user chose.
    func sizeColumnToFit(_ column: DataGridColumn) {
        setWidths([column.id: fittedWidth(for: column)])
    }

    func sizeAllColumnsToFit() {
        let columns = model.columns.columns
        let calculator = widthCalculator()
        var widths: [DataGridColumnID: CGFloat] = [:]
        for column in columns {
            widths[column.id] = calculator.fittedWidth(
                widthInput(for: column),
                availableWidth: visibleGridWidth,
                fittedColumnCount: columns.count
            )
        }
        setWidths(widths)
    }

    private func setWidths(_ widths: [DataGridColumnID: CGFloat]) {
        isRebuildingColumns = true
        var named: [String: CGFloat] = [:]
        for (id, width) in widths {
            for pane in panes {
                pane.tableColumn(for: id)?.width = width
            }
            if let column = main.tableColumn(for: id) {
                named[id.name] = column.width
                savedWidthIDs.insert(id)
                knownWidths[id] = column.width
            }
        }
        isRebuildingColumns = false
        geometryDidChange()
        model.columnGeometryDidChange(widths: named, order: nil)
    }

    // MARK: - Geometry from the user

    func columnDidResize(_ tableColumn: NSTableColumn, in pane: DataGridPane) {
        guard !isRebuildingColumns, let id = pane.columnID(of: tableColumn) else { return }
        if pane.kind == .frozen, let mainColumn = main.tableColumn(for: id), mainColumn.width != tableColumn.width {
            isRebuildingColumns = true
            mainColumn.width = tableColumn.width
            isRebuildingColumns = false
        }
        savedWidthIDs.insert(id)
        knownWidths[id] = tableColumn.width
        if resolveEffectiveFrozenCount() != effectiveFrozenCount {
            updateFrozenPane()
        }
        geometryDidChange()
        model.columnGeometryDidChange(widths: [id.name: tableColumn.width], order: nil)
    }

    func columnDidMove(from oldIndex: Int, to newIndex: Int, in pane: DataGridPane) {
        guard !isRebuildingColumns else { return }
        if pane.kind == .frozen {
            isRebuildingColumns = true
            main.tableView.moveColumn(oldIndex, toColumn: newIndex)
            isRebuildingColumns = false
        }
        let order = main.tableView.tableColumns.compactMap { main.columnID(of: $0)?.name }
        panes.forEach { $0.invalidateSlots() }
        geometryDidChange()
        model.columnGeometryDidChange(widths: [:], order: order)
    }

    // The body has no cell views for AppKit to relay out, so every width, order or freeze step repaints it (#2449).
    func geometryDidChange() {
        if !frozen.tableView.tableColumns.isEmpty {
            container.frozenPaneWidth = frozen.columnsWidth
        }
        for pane in panes {
            pane.tableView.setNeedsDisplay(pane.tableView.visibleRect)
        }
        redrawVisibleRows()
        updateReorderToolTip()
    }

    func tableDidMoveColumn(_ table: DataGridTableView) {
        container.pane(of: table)?.invalidateSlots()
        guard !isRebuildingColumns else { return }
        redrawVisibleRows()
    }

    // A frozen column resized in its own header carries the main pane's copy with it on every step.
    func headerGeometryDidStep(in kind: DataGridPane.Kind) {
        if kind == .frozen {
            isRebuildingColumns = true
            for tableColumn in frozen.tableView.tableColumns {
                guard let id = frozen.columnID(of: tableColumn),
                      let mainColumn = main.tableColumn(for: id),
                      mainColumn.width != tableColumn.width else { continue }
                mainColumn.width = tableColumn.width
            }
            isRebuildingColumns = false
        }
        geometryDidChange()
    }

    func shouldReorderColumn(_ index: Int, to newIndex: Int, in pane: DataGridPane) -> Bool {
        let table = pane.tableView
        guard table.tableColumns.indices.contains(index), !pane.isRowNumber(table.tableColumns[index]) else { return false }
        let leading = pane.hasRowNumberColumn ? 1 : 0
        switch pane.kind {
        case .main:
            // Columns under the frozen pane move in the frozen header, never in this one.
            let firstMovable = leading + effectiveFrozenCount
            guard index >= firstMovable else { return false }
            return newIndex < 0 || newIndex >= firstMovable
        case .frozen:
            return newIndex < 0 || newIndex >= leading
        }
    }

    // MARK: - Frozen pane edge

    // A 1 pt separator after the row numbers alone, a 2 pt divider once columns are frozen.
    func drawFrozenPaneEdge(in rect: NSRect, of view: NSView) {
        let table = frozen.tableView
        guard !table.tableColumns.isEmpty else { return }
        let thickness = effectiveFrozenCount > 0 ? DataGridMetrics.frozenDividerThickness : DataGridBodyChrome.separatorThickness
        let edge = view.convert(NSRect(x: frozen.columnsWidth - thickness, y: 0, width: thickness, height: 1), from: table)
        let divider = NSRect(x: edge.minX, y: rect.minY, width: thickness, height: rect.height)
        guard divider.intersects(rect) else { return }
        table.gridColor.setFill()
        divider.fill()
    }

    // MARK: - Reveal

    // Widened leftward by the frozen pane, so a revealed column never parks beneath it; a frozen column is always shown.
    func revealRect(for rect: NSRect, in table: DataGridTableView) -> NSRect {
        let frozenWidth = frozen.scrollView.isHidden ? 0 : container.frozenPaneWidth
        guard frozenWidth > 0 else { return rect }
        let visible = table.visibleRect
        if rect.maxX <= frozenWidth {
            return NSRect(x: visible.minX, y: rect.minY, width: min(rect.width, visible.width), height: rect.height)
        }
        guard rect.width < visible.width - frozenWidth else { return rect }
        return NSRect(x: rect.minX - frozenWidth, y: rect.minY, width: rect.width + frozenWidth, height: rect.height)
    }
}
