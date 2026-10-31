//
//  DataGridViewController+HeaderMenu.swift
//  TablePro
//

import AppKit

struct DataGridDisplayFormatChoice {
    let columnID: DataGridColumnID
    let format: ValueDisplayFormat
}

extension DataGridViewController {
    func buildHeaderMenu(for column: DataGridColumn) -> NSMenu? {
        guard let position = model.columns.displayPosition(of: column.id) else { return nil }
        let commands = gridCommands
        let configuration = model.configuration
        let columnID = column.id
        var groups: [[NSMenuItem]] = []

        if configuration.supportsColumnSort {
            var sort = [
                menuItem(String(localized: "Sort Ascending"), #selector(sortAscendingFromMenu(_:)), columnID),
                menuItem(String(localized: "Sort Descending"), #selector(sortDescendingFromMenu(_:)), columnID),
            ]
            if model.store.sortState.isSorting {
                sort.append(menuItem(String(localized: "Don't Sort"), #selector(clearSortFromMenu(_:)), nil))
            }
            groups.append(sort)
        }

        var columnItems: [NSMenuItem] = []
        if model.rowCount > 0 {
            columnItems.append(menuItem(String(localized: "Select Column"), #selector(selectColumnFromMenu(_:)), columnID))
        }
        columnItems.append(menuItem(String(localized: "Copy Column Name"), #selector(copyColumnNameFromMenu(_:)), columnID))
        if model.rowCount > 0 {
            columnItems.append(menuItem(String(localized: "Copy Column Values"), #selector(copyColumnValuesFromMenu(_:)), columnID))
        }
        if commands.canFillColumn(column) {
            columnItems.append(menuItem(String(localized: "Fill Column…"), #selector(fillColumnFromMenu(_:)), columnID))
        }
        if commands.offers(.filterWithColumn) {
            columnItems.append(menuItem(String(localized: "Filter with column"), #selector(filterWithColumnFromMenu(_:)), columnID))
        }
        if offersValueFilter {
            let filter = model.store.valueFilter
            columnItems.append(menuItem(String(localized: "Filter Values…"), #selector(filterValuesFromMenu(_:)), columnID))
            if filter.isActive(column: column.dataIndex) {
                columnItems.append(menuItem(String(localized: "Clear Value Filter"), #selector(clearValueFilterFromMenu(_:)), columnID))
            }
            if filter.isActive {
                columnItems.append(menuItem(String(localized: "Clear All Value Filters"), #selector(clearAllValueFiltersFromMenu(_:)), nil))
            }
        }
        if commands.offers(.highlightValues), let highlight = model.actions?.gridHighlightValuesMenuItem(for: column) {
            columnItems.append(highlight)
        }
        if commands.offers(.displayAs), let displayAs = displayAsItem(for: column) {
            columnItems.append(displayAs)
        }
        groups.append(columnItems)

        groups.append([
            menuItem(String(localized: "Size to Fit"), #selector(sizeColumnToFitFromMenu(_:)), columnID),
            menuItem(String(localized: "Size All Columns to Fit"), #selector(sizeAllColumnsToFitFromMenu(_:)), nil),
        ])

        if commands.offers(.hideColumns) {
            var visibility = [menuItem(String(localized: "Hide Column"), #selector(hideColumnFromMenu(_:)), columnID)]
            if !model.store.columnLayout.hiddenColumns.isEmpty {
                visibility.append(menuItem(String(localized: "Show All Columns"), #selector(showAllColumnsFromMenu(_:)), nil))
            }
            groups.append(visibility)
        }

        if commands.offers(.freezeColumns) {
            groups.append(freezeItems(position: position, columnID: columnID))
        }

        groups.append(model.actions?.gridColumnMenuItems(for: column) ?? [])
        return Self.menu(groups: groups)
    }

    var offersValueFilter: Bool {
        gridCommands.offers(.valueFilter) && model.configuration.supportsValueFilter
    }

    private func displayAsItem(for column: DataGridColumn) -> NSMenuItem? {
        let formats = ValueDisplayFormat.applicableFormats(for: column.type, databaseType: model.configuration.traits.databaseType)
        guard formats.count > 1 else { return nil }
        let current = model.displayFormat(for: column) ?? .raw
        let submenu = NSMenu()
        for format in formats {
            let item = menuItem(
                format.displayName,
                #selector(setDisplayFormatFromMenu(_:)),
                DataGridDisplayFormatChoice(columnID: column.id, format: format)
            )
            item.state = format == current ? .on : .off
            submenu.addItem(item)
        }
        if ValueDisplayFormat.offersAvro(for: column.type, databaseType: model.configuration.traits.databaseType) {
            if case .avro = current {
                let item = menuItem(
                    current.displayName,
                    #selector(setDisplayFormatFromMenu(_:)),
                    DataGridDisplayFormatChoice(columnID: column.id, format: current)
                )
                item.state = .on
                submenu.addItem(item)
            }
            submenu.addItem(menuItem(String(localized: "Avro Schema…"), #selector(chooseAvroSchemaFromMenu(_:)), column.id))
        }
        let item = NSMenuItem(title: String(localized: "Display As"), action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    // Refused, with the reason, when the frozen run would leave too little of the grid to scroll.
    private func freezeItems(position: Int, columnID: DataGridColumnID) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let frozenCount = model.columns.frozenCount
        if frozenCount != position + 1 {
            let fits = canFreezeColumns(throughDisplayPosition: position)
            let item = menuItem(
                String(localized: "Freeze Up to This Column"),
                fits ? #selector(freezeColumnsFromMenu(_:)) : nil,
                columnID
            )
            if !fits {
                item.toolTip = String(localized: "These columns would leave too little room to scroll the rest.")
            }
            items.append(item)
        }
        if frozenCount > 0 {
            items.append(menuItem(String(localized: "Unfreeze Columns"), #selector(unfreezeColumnsFromMenu(_:)), nil))
        }
        return items
    }

    // MARK: - Actions

    static let headerMenuActions: Set<Selector> = [
        #selector(DataGridViewController.sortAscendingFromMenu(_:)),
        #selector(DataGridViewController.sortDescendingFromMenu(_:)),
        #selector(DataGridViewController.clearSortFromMenu(_:)),
        #selector(DataGridViewController.selectColumnFromMenu(_:)),
        #selector(DataGridViewController.copyColumnNameFromMenu(_:)),
        #selector(DataGridViewController.copyColumnValuesFromMenu(_:)),
        #selector(DataGridViewController.fillColumnFromMenu(_:)),
        #selector(DataGridViewController.filterWithColumnFromMenu(_:)),
        #selector(DataGridViewController.filterValuesFromMenu(_:)),
        #selector(DataGridViewController.clearValueFilterFromMenu(_:)),
        #selector(DataGridViewController.clearAllValueFiltersFromMenu(_:)),
        #selector(DataGridViewController.setDisplayFormatFromMenu(_:)),
        #selector(DataGridViewController.chooseAvroSchemaFromMenu(_:)),
        #selector(DataGridViewController.sizeColumnToFitFromMenu(_:)),
        #selector(DataGridViewController.sizeAllColumnsToFitFromMenu(_:)),
        #selector(DataGridViewController.hideColumnFromMenu(_:)),
        #selector(DataGridViewController.showAllColumnsFromMenu(_:)),
        #selector(DataGridViewController.freezeColumnsFromMenu(_:)),
        #selector(DataGridViewController.unfreezeColumnsFromMenu(_:)),
    ]

    // The column the item was built for, if the result still presents it.
    private func menuColumn(_ sender: Any?) -> DataGridColumn? {
        guard let id = (sender as? NSMenuItem)?.representedObject as? DataGridColumnID else { return nil }
        return model.columns.column(id: id)
    }

    @objc func sortAscendingFromMenu(_ sender: Any?) {
        sort(menuColumn(sender), direction: .ascending)
    }

    @objc func sortDescendingFromMenu(_ sender: Any?) {
        sort(menuColumn(sender), direction: .descending)
    }

    // Replaces the whole sort, stamped as the user's so the app default never writes over it.
    private func sort(_ column: DataGridColumn?, direction: SortDirection) {
        guard let column, model.configuration.supportsColumnSort else { return }
        model.setSort(SortState(
            columns: [SortColumn(columnIndex: column.dataIndex, direction: direction, columnName: column.name)],
            source: .user
        ))
    }

    // The user's own empty sort, which keeps the app default from coming back on the next load.
    @objc func clearSortFromMenu(_ sender: Any?) {
        model.setSort(SortState(columns: [], source: .user))
    }

    // Focuses the grid too, so the Copy that usually follows acts on the column.
    @objc func selectColumnFromMenu(_ sender: Any?) {
        guard let column = menuColumn(sender),
              let position = model.columns.displayPosition(of: column.id),
              model.rowCount > 0 else { return }
        model.setSelection(GridSelection.column(position, totalRows: model.rowCount))
        mirrorSelection()
        focus()
    }

    @objc func copyColumnNameFromMenu(_ sender: Any?) {
        guard let column = menuColumn(sender) else { return }
        ClipboardService.shared.writeText(column.name)
    }

    @objc func copyColumnValuesFromMenu(_ sender: Any?) {
        guard let column = menuColumn(sender) else { return }
        gridCommands.copyColumnValues(column)
    }

    @objc func fillColumnFromMenu(_ sender: Any?) {
        guard let column = menuColumn(sender) else { return }
        presentFillColumn(for: column)
    }

    @objc func filterWithColumnFromMenu(_ sender: Any?) {
        guard let column = menuColumn(sender) else { return }
        model.actions?.gridFilterWithColumn(column)
    }

    @objc func filterValuesFromMenu(_ sender: Any?) {
        guard let column = menuColumn(sender) else { return }
        presentValueFilter(for: column)
    }

    @objc func clearValueFilterFromMenu(_ sender: Any?) {
        guard let column = menuColumn(sender) else { return }
        applyValueFilter(nil, to: column)
    }

    @objc func clearAllValueFiltersFromMenu(_ sender: Any?) {
        clearAllValueFilters()
    }

    // Only a value filter can renumber rows on a format change, so only then does the owner confirm it.
    @objc func setDisplayFormatFromMenu(_ sender: Any?) {
        guard let choice = (sender as? NSMenuItem)?.representedObject as? DataGridDisplayFormatChoice else { return }
        setDisplayFormat(choice.format, columnID: choice.columnID)
    }

    private func setDisplayFormat(_ format: ValueDisplayFormat, columnID: DataGridColumnID) {
        guard model.columns.column(id: columnID) != nil else { return }
        let apply: @MainActor () -> Void = { [weak self] in
            guard let self, let column = self.model.columns.column(id: columnID) else { return }
            self.model.setDisplayFormat(format, for: column)
        }
        guard model.store.valueFilter.isActive, let actions = model.actions else {
            apply()
            return
        }
        actions.gridConfirmDisplayOrderChange(then: apply)
    }

    // The schema is copied in, so the column still decodes after the file moves.
    @objc func chooseAvroSchemaFromMenu(_ sender: Any?) {
        guard let columnID = menuColumn(sender)?.id, let window = view.window else { return }
        Task { @MainActor [weak self] in
            guard let text = await AvroSchemaFilePanel.chooseSchemaText(in: window) else { return }
            let format: ValueDisplayFormat
            do {
                format = .avro(schemaID: try AvroSchemaStore.shared.add(text))
            } catch {
                NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil)
                return
            }
            guard let self else { return }
            if let column = model.columns.column(id: columnID), model.displayFormat(for: column) == format {
                model.redisplay(column)
            } else {
                setDisplayFormat(format, columnID: columnID)
            }
        }
    }

    @objc func sizeColumnToFitFromMenu(_ sender: Any?) {
        guard let column = menuColumn(sender) else { return }
        sizeColumnToFit(column)
    }

    @objc func sizeAllColumnsToFitFromMenu(_ sender: Any?) {
        sizeAllColumnsToFit()
    }

    @objc func hideColumnFromMenu(_ sender: Any?) {
        guard let column = menuColumn(sender) else { return }
        model.actions?.gridHideColumn(column)
    }

    @objc func showAllColumnsFromMenu(_ sender: Any?) {
        model.actions?.gridShowAllColumns()
    }

    @objc func freezeColumnsFromMenu(_ sender: Any?) {
        guard let column = menuColumn(sender),
              let position = model.columns.displayPosition(of: column.id),
              canFreezeColumns(throughDisplayPosition: position) else { return }
        model.updateColumnLayout { $0.frozenColumnCount = position + 1 }
    }

    @objc func unfreezeColumnsFromMenu(_ sender: Any?) {
        model.updateColumnLayout { $0.frozenColumnCount = 0 }
    }
}
