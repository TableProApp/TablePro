//
//  DataGridColumnPool.swift
//  TablePro
//

import AppKit

@MainActor
final class DataGridColumnPool {
    private var pooledColumns: [NSTableColumn] = []
    private weak var attachedTableView: NSTableView?

    /// Columns the user hid, kept apart from the ones the window unmounts so a window slide can
    /// never bring a hidden column back.
    private var userHiddenIdentifiers: Set<NSUserInterfaceItemIdentifier> = []
    /// Slots the current result actually uses. The pool only grows, so the surplus slots past the
    /// result's column count stay attached and hidden, and windowing must never mount one.
    private var activeIdentifiers: Set<NSUserInterfaceItemIdentifier> = []
    private var windowedRange: Range<Int>?

    private lazy var leadingSpacer = Self.makeSpacer(ColumnIdentitySchema.leadingSpacerIdentifier)
    private lazy var trailingSpacer = Self.makeSpacer(ColumnIdentitySchema.trailingSpacerIdentifier)

    var totalSlots: Int { pooledColumns.count }

    private static func makeSpacer(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableColumn {
        let column = NSTableColumn(identifier: identifier)
        column.minWidth = 0
        column.maxWidth = .greatestFiniteMagnitude
        column.width = 0
        column.resizingMask = []
        column.isEditable = false
        column.isHidden = true
        // The data grid header owns all of its own chrome (#2017): NSTableHeaderCell paints a fixed
        // 28pt band with a divider and a rule that land mid-cell in this header's 42pt. A spacer is
        // normally off screen, but it must not be the one cell that asks AppKit to paint.
        column.headerCell = SortableHeaderCell(textCell: "")
        return column
    }

    func attach(to tableView: NSTableView) {
        attachedTableView = tableView
    }

    /// Whether the result presents this column at all, which is a different question from whether
    /// the window currently has it mounted.
    ///
    /// `isHidden` answers both at once, and everything that asks "which columns is the user
    /// looking at" (copy, find, cell navigation, size-all) means this one. Reading `isHidden`
    /// there silently narrows those to the columns near the viewport.
    func presentsColumn(_ column: NSTableColumn) -> Bool {
        activeIdentifiers.contains(column.identifier) && !userHiddenIdentifiers.contains(column.identifier)
    }

    var hasUserHiddenColumns: Bool { !userHiddenIdentifiers.isEmpty }

    func detachFromTableView() {
        guard let tableView = attachedTableView else { return }
        let attached = Set(tableView.tableColumns.map(\.identifier))
        for column in pooledColumns where attached.contains(column.identifier) {
            tableView.removeTableColumn(column)
        }
        for spacer in [leadingSpacer, trailingSpacer] where attached.contains(spacer.identifier) {
            tableView.removeTableColumn(spacer)
        }
        windowedRange = nil
        attachedTableView = nil
    }

    func reconcile(
        tableView: NSTableView,
        schema: ColumnIdentitySchema,
        columnTypes: [ColumnType],
        columnComments: [String: String] = [:],
        savedLayout: ColumnLayoutState?,
        isEditable: Bool,
        hiddenColumnNames: Set<String>,
        widthCalculator: (String, Int) -> CGFloat
    ) {
        attach(to: tableView)
        let visibleCount = schema.columnNames.count
        activeIdentifiers = Set(schema.identifiers)

        growBackingPoolIfNeeded(to: visibleCount)

        let willRestoreWidths = !(savedLayout?.columnWidths.isEmpty ?? true)
        let hiddenFromLayout = savedLayout?.hiddenColumns ?? []
        var comments: [NSUserInterfaceItemIdentifier: String] = [:]
        var showsComments = false

        for slot in 0..<pooledColumns.count {
            let column = pooledColumns[slot]
            if slot < visibleCount {
                let columnName = schema.columnNames[slot]
                let resolvedWidth = willRestoreWidths
                    ? (savedLayout?.columnWidths[columnName] ?? widthCalculator(columnName, slot))
                    : widthCalculator(columnName, slot)
                let comment = displayableComment(columnComments[columnName])
                configureColumn(
                    column,
                    name: columnName,
                    columnType: slot < columnTypes.count ? columnTypes[slot] : nil,
                    comment: comment,
                    width: resolvedWidth,
                    isEditable: isEditable
                )
                let hidden = hiddenFromLayout.contains(columnName) || hiddenColumnNames.contains(columnName)
                if hidden {
                    userHiddenIdentifiers.insert(column.identifier)
                } else {
                    userHiddenIdentifiers.remove(column.identifier)
                }
                if column.isHidden != hidden {
                    column.isHidden = hidden
                }
                if let comment {
                    comments[column.identifier] = comment
                    if !hidden {
                        showsComments = true
                    }
                }
            } else if !column.isHidden {
                column.isHidden = true
            }
        }
        applyComments(comments, showsComments: showsComments, in: tableView)

        let targetOrder = computeTargetOrder(
            visibleCount: visibleCount,
            savedOrder: savedLayout?.columnOrder,
            schema: schema
        )

        attachAndOrderColumns(
            in: tableView,
            visibleCount: visibleCount,
            targetOrder: targetOrder
        )

        windowedRange = nil
        applyColumnWindow(in: tableView)
    }

    /// The window is resolved from the column widths, so a width changed outside `reconcile` has to
    /// drop it or the spacers keep standing in at the old total and the scroll extent is short.
    func invalidateColumnWindow() {
        windowedRange = nil
    }

    /// Unmounts the columns the viewport cannot reach and gives their width to the spacers.
    ///
    /// `NSTableView` builds a cell view per non-hidden column for every prepared row, so a 500
    /// column result holds ~18,000 live views and lays all of them out on every scroll frame.
    /// Hiding the far ones is measurably close to free; the spacers keep the document width and
    /// therefore the scroll extent identical to mounting everything.
    func applyColumnWindow(in tableView: NSTableView) {
        let candidates = presentedColumns(in: tableView)
        guard !candidates.isEmpty else {
            hideSpacers()
            return
        }

        let viewport = tableView.enclosingScrollView?.contentView.bounds ?? tableView.visibleRect
        guard viewport.width > 0 else {
            unmountNothing(candidates)
            return
        }

        // A mounted column contributes its width plus one intercell gap; a hidden one contributes
        // nothing. A spacer standing in for N columns has to carry their gaps too, or the document
        // ends up short and the last columns cannot be reached.
        let spacing = tableView.intercellSpacing.width
        let window = ColumnWindowResolver.resolve(
            columnWidths: candidates.map { $0.width + spacing },
            viewportMinX: viewport.minX - leadingChromeWidth(in: tableView, before: candidates[0]),
            viewportWidth: viewport.width,
            current: windowedRange
        )
        guard window.range != windowedRange else { return }
        mount(window, over: candidates, in: tableView)
    }

    /// Mounts a column the window left out, so anything that reads its frame gets a real rect.
    ///
    /// `rect(ofColumn:)` and `frameOfCell(atColumn:row:)` are both empty for a hidden column, so
    /// `scrollColumnToVisible` scrolls to the document origin instead of the column, and the inline
    /// editor's own empty-frame guard makes it open nothing at all (#2381).
    /// - Returns: whether the window had to widen, so the caller can drop it and let the next
    ///   resolve pick a tight one instead of leaving the widened range mounted.
    @discardableResult
    func mountColumn(_ column: NSTableColumn, in tableView: NSTableView) -> Bool {
        guard presentsColumn(column) else { return false }
        let candidates = presentedColumns(in: tableView)
        guard let position = candidates.firstIndex(of: column) else { return false }

        let spacing = tableView.intercellSpacing.width
        guard let window = ColumnWindowResolver.window(
            containing: position,
            columnWidths: candidates.map { $0.width + spacing },
            current: windowedRange
        ) else { return false }
        mount(window, over: candidates, in: tableView)
        return true
    }

    /// The first and last columns the result presents, in display order. The pool owns these
    /// because the spacers are attached columns too and one of them sits immediately before the
    /// first data column, so no fixed position can name either end.
    func firstPresentedColumnIndex(in tableView: NSTableView) -> Int? {
        tableView.tableColumns.firstIndex { presentsColumn($0) }
    }

    func lastPresentedColumnIndex(in tableView: NSTableView) -> Int? {
        tableView.tableColumns.lastIndex { presentsColumn($0) }
    }

    func nextPresentedColumnIndex(after index: Int, in tableView: NSTableView) -> Int? {
        let start = max(0, index + 1)
        guard start < tableView.tableColumns.count else { return nil }
        return tableView.tableColumns[start...].firstIndex { presentsColumn($0) }
    }

    func previousPresentedColumnIndex(before index: Int, in tableView: NSTableView) -> Int? {
        let end = min(max(0, index), tableView.tableColumns.count)
        guard end > 0 else { return nil }
        return tableView.tableColumns[..<end].lastIndex { presentsColumn($0) }
    }

    func presentsColumn(atTableColumnIndex index: Int, in tableView: NSTableView) -> Bool {
        guard index >= 0, index < tableView.tableColumns.count else { return false }
        return presentsColumn(tableView.tableColumns[index])
    }

    private func presentedColumns(in tableView: NSTableView) -> [NSTableColumn] {
        tableView.tableColumns.filter { presentsColumn($0) }
    }

    private func mount(
        _ window: ColumnWindowResolver.Window,
        over candidates: [NSTableColumn],
        in tableView: NSTableView
    ) {
        windowedRange = window.range
        for (index, column) in candidates.enumerated() {
            let mounted = window.range.contains(index)
            if column.isHidden == mounted {
                column.isHidden = !mounted
            }
        }
        let spacing = tableView.intercellSpacing.width
        applySpacer(leadingSpacer, width: spacerWidth(window.leadingWidth, spacing: spacing), in: tableView)
        applySpacer(trailingSpacer, width: spacerWidth(window.trailingWidth, spacing: spacing), in: tableView)
    }

    /// The document starts at the row-number column, but the resolver measures from the first data
    /// column, so the viewport has to be rebased before it can index into those widths.
    ///
    /// Only chrome counts. The leading spacer sits ahead of the first data column and holds exactly
    /// the width of the columns the window left out, which the resolver's own model already carries,
    /// so counting it here subtracts that width twice and walks the window left while the reader
    /// scrolls right, until it parks off screen and the grid paints nothing (#2381).
    private func leadingChromeWidth(in tableView: NSTableView, before firstColumn: NSTableColumn) -> CGFloat {
        tableView.tableColumns
            .prefix { $0.identifier != firstColumn.identifier }
            .filter { !$0.isHidden && !ColumnIdentitySchema.isSpacer($0.identifier) }
            .reduce(0) { $0 + $1.width + tableView.intercellSpacing.width }
    }

    /// The resolver works in per-column slots that already include one gap each. A spacer is a
    /// single column, so it keeps one gap of its own and absorbs the rest as width.
    private func spacerWidth(_ slotWidth: CGFloat, spacing: CGFloat) -> CGFloat {
        guard slotWidth > 0 else { return 0 }
        return max(0, slotWidth - spacing)
    }

    /// A table that has not been laid out yet reports no viewport, and windowing against that would
    /// hide every column. Mount everything until there is a real width to measure against.
    private func unmountNothing(_ candidates: [NSTableColumn]) {
        windowedRange = nil
        for column in candidates where column.isHidden {
            column.isHidden = false
        }
        hideSpacers()
    }

    private func applySpacer(_ spacer: NSTableColumn, width: CGFloat, in tableView: NSTableView) {
        if spacer.width != width {
            spacer.width = width
        }
        let hidden = width <= 0
        if spacer.isHidden != hidden {
            spacer.isHidden = hidden
        }
    }

    private func hideSpacers() {
        for spacer in [leadingSpacer, trailingSpacer] where !spacer.isHidden {
            spacer.isHidden = true
            spacer.width = 0
        }
    }

    private func growBackingPoolIfNeeded(to count: Int) {
        while pooledColumns.count < count {
            let slot = pooledColumns.count
            let column = NSTableColumn(identifier: ColumnIdentitySchema.slotIdentifier(slot))
            column.minWidth = DataGridMetrics.dataColumnMinWidth
            column.maxWidth = DataGridMetrics.dataColumnMaxWidth
            column.resizingMask = .userResizingMask
            column.isEditable = true
            column.isHidden = true
            pooledColumns.append(column)
        }
    }

    private func computeTargetOrder(
        visibleCount: Int,
        savedOrder: [String]?,
        schema: ColumnIdentitySchema
    ) -> [Int] {
        var slots: [Int] = []
        var seen = Set<Int>()

        if let savedOrder {
            for name in savedOrder {
                guard let slot = schema.dataIndex(forColumnName: name),
                      slot < visibleCount,
                      !seen.contains(slot) else { continue }
                slots.append(slot)
                seen.insert(slot)
            }
        }

        for slot in 0..<visibleCount where !seen.contains(slot) {
            slots.append(slot)
        }
        return slots
    }

    private func attachAndOrderColumns(
        in tableView: NSTableView,
        visibleCount: Int,
        targetOrder: [Int]
    ) {
        var attached = Set(tableView.tableColumns.map(\.identifier))
        let baseOffset = tableView.tableColumns.first?.identifier == ColumnIdentitySchema.rowNumberIdentifier ? 1 : 0

        for slot in targetOrder where !attached.contains(pooledColumns[slot].identifier) {
            tableView.addTableColumn(pooledColumns[slot])
            attached.insert(pooledColumns[slot].identifier)
        }

        for slot in 0..<pooledColumns.count
        where slot >= visibleCount && !attached.contains(pooledColumns[slot].identifier) {
            tableView.addTableColumn(pooledColumns[slot])
            attached.insert(pooledColumns[slot].identifier)
        }

        for spacer in [leadingSpacer, trailingSpacer] where !attached.contains(spacer.identifier) {
            tableView.addTableColumn(spacer)
            attached.insert(spacer.identifier)
        }

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        defer { NSAnimationContext.endGrouping() }

        var indexByIdentifier: [NSUserInterfaceItemIdentifier: Int] = [:]
        indexByIdentifier.reserveCapacity(tableView.tableColumns.count)
        for (index, column) in tableView.tableColumns.enumerated() {
            indexByIdentifier[column.identifier] = index
        }

        for (targetPosition, slot) in targetOrder.enumerated() {
            let identifier = ColumnIdentitySchema.slotIdentifier(slot)
            guard let currentIndex = indexByIdentifier[identifier] else { continue }
            let desiredIndex = baseOffset + targetPosition
            guard desiredIndex < tableView.tableColumns.count else { continue }
            if currentIndex == desiredIndex { continue }

            tableView.moveColumn(currentIndex, toColumn: desiredIndex)
            updateIndexMap(&indexByIdentifier, movedFrom: currentIndex, to: desiredIndex)
        }

        positionSpacers(in: tableView, baseOffset: baseOffset)
    }

    /// The leading spacer stands in for everything scrolled off to the left, so it has to sit ahead
    /// of the first data column; the trailing spacer holds the rest and sits last.
    private func positionSpacers(in tableView: NSTableView, baseOffset: Int) {
        move(leadingSpacer, to: baseOffset, in: tableView)
        move(trailingSpacer, to: tableView.tableColumns.count - 1, in: tableView)
    }

    private func move(_ column: NSTableColumn, to index: Int, in tableView: NSTableView) {
        guard let current = tableView.tableColumns.firstIndex(of: column) else { return }
        let clamped = max(0, min(index, tableView.tableColumns.count - 1))
        guard current != clamped else { return }
        tableView.moveColumn(current, toColumn: clamped)
    }

    private func updateIndexMap(
        _ map: inout [NSUserInterfaceItemIdentifier: Int],
        movedFrom source: Int,
        to destination: Int
    ) {
        guard source != destination else { return }
        let lower = min(source, destination)
        let upper = max(source, destination)
        let delta = source < destination ? -1 : 1
        for (key, value) in map where value >= lower && value <= upper {
            if value == source {
                map[key] = destination
            } else {
                map[key] = value + delta
            }
        }
    }

    private func configureColumn(
        _ column: NSTableColumn,
        name: String,
        columnType: ColumnType?,
        comment: String?,
        width: CGFloat,
        isEditable: Bool
    ) {
        if !(column.headerCell is SortableHeaderCell) || column.headerCell.stringValue != name {
            let cell = SortableHeaderCell(textCell: name)
            cell.font = column.headerCell.font
            cell.alignment = column.headerCell.alignment
            column.headerCell = cell
        }

        var tooltip: String
        if let typeName = columnType?.rawType ?? columnType?.displayName {
            tooltip = "\(name) (\(typeName))"
        } else {
            tooltip = name
        }
        if let comment {
            tooltip += "\n\(comment)"
        }
        if column.headerToolTip != tooltip {
            column.headerToolTip = tooltip
        }

        let label = accessibilityLabel(name: name, comment: comment)
        if column.headerCell.accessibilityLabel() != label {
            column.headerCell.setAccessibilityLabel(label)
        }

        if column.width != width {
            column.width = width
        }
        if column.isEditable != isEditable {
            column.isEditable = isEditable
        }
        if column.sortDescriptorPrototype?.key != name {
            column.sortDescriptorPrototype = NSSortDescriptor(key: name, ascending: true)
        }
    }

    private func accessibilityLabel(name: String, comment: String?) -> String {
        let label = String(format: String(localized: "Column: %@"), name)
        guard let comment else { return label }
        return "\(label), \(comment)"
    }

    private func displayableComment(_ comment: String?) -> String? {
        guard let comment else { return nil }
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func applyComments(
        _ comments: [NSUserInterfaceItemIdentifier: String],
        showsComments: Bool,
        in tableView: NSTableView
    ) {
        guard let headerView = tableView.headerView as? SortableHeaderView else { return }
        headerView.showsComments = showsComments
        headerView.updateComments(comments)
    }
}
