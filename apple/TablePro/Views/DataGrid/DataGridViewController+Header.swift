//
//  DataGridViewController+Header.swift
//  TablePro
//

import AppKit
import TableProTheme

extension DataGridViewController {
    // The sort entries the current result carries a column for, resolved by name: a stale index would put the
    // indicator on whichever column moved into the slot.
    func presentedSortEntries() -> [(column: DataGridColumn, direction: SortDirection)] {
        guard model.configuration.supportsColumnSort else { return [] }
        let names = model.rows.columns
        let columns = model.columns
        return model.store.sortState.columns.compactMap { sortColumn -> (column: DataGridColumn, direction: SortDirection)? in
            guard let name = SortColumnResolver.columnName(for: sortColumn, displayColumns: names) else { return nil }
            let dataIndex: Int
            if sortColumn.columnIndex >= 0, sortColumn.columnIndex < names.count, names[sortColumn.columnIndex] == name {
                dataIndex = sortColumn.columnIndex
            } else if let found = names.firstIndex(of: name) {
                dataIndex = found
            } else {
                return nil
            }
            guard let position = columns.displayPosition(ofDataIndex: dataIndex),
                  let column = columns.column(at: position) else { return nil }
            return (column: column, direction: sortColumn.direction)
        }
    }

    // The model's sort is the source; tableView.sortDescriptors follows it under a guard, since assigning inside the
    // callback re-enters it once (probe P5b).
    func sortDidChange() {
        syncSortIndicators()
    }

    func summaryRulesDidChange() {
        selectionSummaryTracker.rulesDidChange()
    }

    func syncSortIndicators() {
        let descriptors = presentedSortEntries().map {
            NSSortDescriptor(key: $0.column.id.stringValue, ascending: $0.direction == .ascending)
        }
        isApplyingSortDescriptors = true
        for pane in panes {
            let current = pane.tableView.sortDescriptors
            let same = current.count == descriptors.count
                && zip(current, descriptors).allSatisfy { $0.key == $1.key && $0.ascending == $1.ascending }
            if !same {
                pane.tableView.sortDescriptors = descriptors
            }
        }
        isApplyingSortDescriptors = false
        refreshHeaders()
    }

    func headerPressed(_ tableColumn: NSTableColumn, in pane: DataGridPane) {
        pendingHeaderPress = (pane.kind, tableColumn.identifier)
    }

    // AppKit already put the clicked key first; a plain click keeps only it, Option-click keeps AppKit's appended key.
    func sortDescriptorsDidChange(in pane: DataGridPane) {
        guard !isApplyingSortDescriptors, model.configuration.supportsColumnSort else { return }
        let column = clickedSortColumn(in: pane)
        pendingHeaderPress = nil
        guard let column else {
            syncSortIndicators()
            return
        }
        let addsKey = NSApp.currentEvent?.modifierFlags.contains(.option) == true
        let current = SortColumnResolver.reindexed(model.store.sortState, displayColumns: model.rows.columns)
        let transition = HeaderSortCycle.nextTransition(
            state: current,
            clickedColumn: column.dataIndex,
            isMultiSort: addsKey,
            firstClickDirection: firstClickSortDirection
        )
        model.setSort(SortColumnResolver.stamped(transition.newState, displayColumns: model.rows.columns))
        syncSortIndicators()
    }

    private func clickedSortColumn(in pane: DataGridPane) -> DataGridColumn? {
        if let press = pendingHeaderPress,
           let tableColumn = container.pane(press.kind).tableView.tableColumns.first(where: { $0.identifier == press.identifier }),
           let id = container.pane(press.kind).columnID(of: tableColumn) {
            return model.columns.column(id: id)
        }
        guard let key = pane.tableView.sortDescriptors.first?.key else { return nil }
        return model.columns.columns.first { $0.id.stringValue == key }
    }

    // Command-click selects the whole column; Shift and Command reach no sort callback at all (critic B M1).
    func headerClicked(_ tableColumn: NSTableColumn, in pane: DataGridPane) {
        guard let event = NSApp.currentEvent, event.modifierFlags.contains(.command),
              let id = pane.columnID(of: tableColumn),
              let position = model.columns.displayPosition(of: id) else { return }
        var modifiers: GridPointerModifiers = .command
        if event.modifierFlags.contains(.shift) {
            modifiers.insert(.shift)
        }
        let next = GridSelectionReducer.columnHeaderCommandClick(
            model.selection,
            column: position,
            modifiers: modifiers,
            in: selectionContext
        )
        model.setSelection(next)
        mirrorSelection()
        focus()
    }

    // Where a popover about a column points: its heading, in the pane that shows it, scrolled into view first.
    func anchor(forColumn displayColumn: Int) -> (view: NSView, rect: NSRect)? {
        let pane = displayColumn < effectiveFrozenCount ? frozen : main
        guard let index = pane.tableIndex(forDisplayPosition: displayColumn, columns: model.columns) else { return nil }
        if pane.isMain {
            revealColumn(displayColumn)
        }
        return (pane.headerView, pane.headerView.headerRect(ofColumn: index))
    }

    // MARK: - Header

    // Titles, the value-filter funnel, tooltips and sort accessibility for every column of both panes.
    func refreshHeaders() {
        let columns = model.columns
        let filter = model.store.valueFilter
        let sortEntries = presentedSortEntries()
        let showsComments = AppSettingsManager.shared.general.showObjectComments
        var sortIndex: [DataGridColumnID: (direction: SortDirection, priority: Int)] = [:]
        for (priority, entry) in sortEntries.enumerated() {
            sortIndex[entry.column.id] = (entry.direction, priority + 1)
        }
        for pane in panes {
            for tableColumn in pane.tableView.tableColumns {
                guard let id = pane.columnID(of: tableColumn), let column = columns.column(id: id) else { continue }
                let sort = sortIndex[id]
                applyHeaderTitle(
                    to: tableColumn,
                    column: column,
                    isFiltered: model.configuration.supportsValueFilter && filter.isActive(column: column.dataIndex)
                )
                let tooltip = headerToolTip(
                    for: column,
                    showsComment: showsComments,
                    sort: sort,
                    sortKeyCount: sortEntries.count
                )
                if tableColumn.headerToolTip != tooltip {
                    tableColumn.headerToolTip = tooltip
                }
                let cell = tableColumn.headerCell
                let label = headerAccessibilityLabel(for: column, showsComment: showsComments)
                if cell.accessibilityLabel() != label {
                    cell.setAccessibilityLabel(label)
                }
                // sortDescriptors reaches no accessibility client: the header cell's direction stays unknown (#2381 era).
                cell.setAccessibilitySortDirection(Self.accessibilitySortDirection(sort?.direction))
            }
            pane.headerView.needsDisplay = true
        }
    }

    private func applyHeaderTitle(to tableColumn: NSTableColumn, column: DataGridColumn, isFiltered: Bool) {
        let cell = tableColumn.headerCell
        guard isFiltered else {
            if cell.stringValue != column.name {
                tableColumn.title = column.name
            }
            return
        }
        let font = cell.font ?? .systemFont(ofSize: NSFont.smallSystemFontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = cell.alignment
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph,
        ]
        let title = NSMutableAttributedString(string: column.name + " ", attributes: attributes)
        if let funnel = Self.filterFunnel(for: font, color: model.themeScope.resolved[.gridHeaderText]) {
            let attachment = NSAttributedString(attachment: funnel)
            let marked = NSMutableAttributedString(attributedString: attachment)
            marked.addAttributes(attributes, range: NSRange(location: 0, length: marked.length))
            title.append(marked)
        }
        cell.attributedStringValue = title
    }

    // A symbol image keeps the color it was built with, so it takes the header text color here.
    private static func filterFunnel(for font: NSFont, color: NSColor) -> NSTextAttachment? {
        let configuration = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
            .applying(.init(hierarchicalColor: color))
        guard let image = NSImage(
            systemSymbolName: "line.3.horizontal.decrease.circle.fill",
            accessibilityDescription: String(localized: "Filtered")
        )?.withSymbolConfiguration(configuration) else { return nil }
        let attachment = NSTextAttachment()
        attachment.image = image
        let size = image.size
        attachment.bounds = NSRect(x: 0, y: (font.capHeight - size.height) / 2, width: size.width, height: size.height)
        return attachment
    }

    private func headerToolTip(
        for column: DataGridColumn,
        showsComment: Bool,
        sort: (direction: SortDirection, priority: Int)?,
        sortKeyCount: Int
    ) -> String {
        var tooltip: String
        if let typeName = column.type?.rawType ?? column.type?.displayName {
            tooltip = column.name + " (" + typeName + ")"
        } else {
            tooltip = column.name
        }
        if showsComment, let comment = Self.displayableComment(column.comment) {
            tooltip += "\n" + comment
        }
        if let sort, sortKeyCount > 1 {
            tooltip += "\n" + String(
                format: String(localized: "Sort key %d of %d, %@"),
                sort.priority,
                sortKeyCount,
                sort.direction.displayName
            )
        }
        return tooltip
    }

    private func headerAccessibilityLabel(for column: DataGridColumn, showsComment: Bool) -> String {
        let label = String(format: String(localized: "Column: %@"), column.name)
        guard showsComment, let comment = Self.displayableComment(column.comment) else { return label }
        return label + ", " + comment
    }

    private static func displayableComment(_ comment: String?) -> String? {
        guard let trimmed = comment?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func accessibilitySortDirection(_ direction: SortDirection?) -> NSAccessibilitySortDirection {
        switch direction {
        case .ascending: return .ascending
        case .descending: return .descending
        case nil: return .unknown
        }
    }

    // A whole column picked by its heading highlights that heading in whichever pane shows it.
    func updateHighlightedColumns(_ selection: GridSelection) {
        let picked = selection.activeCell.flatMap { selection.columns.contains($0.displayColumn) ? $0.displayColumn : nil }
            ?? selection.columns.first
        let id = picked.flatMap { model.columns.column(at: $0)?.id }
        for pane in panes {
            let column = id.flatMap { pane.tableColumn(for: $0) }
            let attached = column.flatMap { candidate in
                pane.tableView.tableColumns.contains { $0 === candidate } ? candidate : nil
            }
            if pane.tableView.highlightedTableColumn !== attached {
                pane.tableView.highlightedTableColumn = attached
            }
        }
    }
}
