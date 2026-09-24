//
//  DataFileSplitViewController+Actions.swift
//  TablePro
//

import AppKit
import TableProTabular

struct DataFileMenuValidation {
    let isEnabled: Bool
    var title: String?
    var state: NSControl.StateValue?
}

extension DataFileSplitViewController {
    @objc func addRow(_ sender: Any?) {
        controller.appendRow()
    }

    @objc func dataFileInsertRowAbove(_ sender: Any?) {
        controller.insertRow(anchoredAtPageRow: anchorRow(from: sender, below: false), below: false)
    }

    @objc func dataFileInsertRowBelow(_ sender: Any?) {
        controller.insertRow(anchoredAtPageRow: anchorRow(from: sender, below: true), below: true)
    }

    @objc func dataFileDeleteSelectedRows(_ sender: Any?) {
        deleteRows(controller.selectedRowIndices)
    }

    func deleteRows(_ pageRows: Set<Int>) {
        guard !pageRows.isEmpty else { return }
        let firstRow = pageRows.min() ?? 0
        let proceed: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            _ = self.controller.deleteRows(pageRows: pageRows)
            let remaining = self.controller.tableRows.rows.count
            self.controller.selectedRowIndices = remaining == 0 ? [] : [min(firstRow, remaining - 1)]
        }
        guard controller.rowsHaveData(pageRows: pageRows) else {
            proceed()
            return
        }
        DataFileDeleteConfirmation.confirm(
            messageText: DataFileDeleteConfirmation.rowDeleteTitle(count: pageRows.count),
            window: view.window,
            proceed: proceed
        )
    }

    @objc func performFind(_ sender: Any?) {
        controller.showFind(replacing: false)
    }

    @objc func performFindAndReplace(_ sender: Any?) {
        controller.showFind(replacing: true)
    }

    @objc func findNext(_ sender: Any?) {
        controller.findNext()
    }

    @objc func findPrevious(_ sender: Any?) {
        controller.findPrevious()
    }

    @objc func useSelectionForFind(_ sender: Any?) {
        controller.useSelectionForFind()
    }

    @objc func toggleFilterBar(_ sender: Any?) {
        controller.filterState.isVisible.toggle()
        if controller.filterState.isVisible, controller.filterState.filters.isEmpty {
            controller.addBlankFilter()
        }
    }

    @objc override func toggleInspector(_ sender: Any?) {
        controller.isInspectorVisible.toggle()
    }

    @objc func dataFileSearchAllColumns(_ sender: Any?) {
        dataFileWindowController?.focusSearchField()
    }

    @objc func dataFileToggleHeaderRow(_ sender: Any?) {
        controller.setUsesFirstRowAsHeader(!controller.usesFirstRowAsHeader)
    }

    @objc func dataFileAddColumn(_ sender: Any?) {
        DataFilePrompts.columnName(title: String(localized: "Add Column"), initial: "", window: view.window) { [weak self] name in
            guard let self, let name else { return }
            self.controller.insertColumn(named: name, at: self.controller.columnNames.count)
        }
    }

    @objc func dataFileInsertColumnLeft(_ sender: Any?) {
        insertColumn(from: sender, toRight: false)
    }

    @objc func dataFileInsertColumnRight(_ sender: Any?) {
        insertColumn(from: sender, toRight: true)
    }

    private func insertColumn(from sender: Any?, toRight: Bool) {
        let anchor = targetColumns(from: sender).first.flatMap { controller.columnNames.index(of: $0) }
        let count = controller.columnNames.count
        let index = anchor.map { toRight ? $0 + 1 : $0 } ?? (toRight ? count : 0)
        DataFilePrompts.columnName(title: String(localized: "Insert Column"), initial: "", window: view.window) { [weak self] name in
            guard let name else { return }
            self?.controller.insertColumn(named: name, at: index)
        }
    }

    @objc func dataFileRenameColumn(_ sender: Any?) {
        guard let id = targetColumns(from: sender).first, let current = controller.columnNames.name(for: id) else { return }
        DataFilePrompts.columnName(title: String(localized: "Rename Column"), initial: current, window: view.window) { [weak self] name in
            guard let name, !name.isEmpty else { return }
            self?.controller.renameColumn(id, to: name)
        }
    }

    @objc func dataFileDeleteColumn(_ sender: Any?) {
        let ids = targetColumns(from: sender)
        guard !ids.isEmpty else { return }
        DataFileDeleteConfirmation.confirm(
            messageText: DataFileDeleteConfirmation.columnDeleteTitle(count: ids.count),
            window: view.window
        ) { [weak self] in
            self?.controller.deleteColumns(Set(ids))
        }
    }

    @objc func dataFileSplitColumn(_ sender: Any?) {
        guard let id = targetColumns(from: sender).first else { return }
        DataFilePrompts.splitSeparator(window: view.window) { [weak self] separator in
            guard let separator else { return }
            self?.controller.splitColumn(id, separator: separator)
        }
    }

    @objc func dataFileMergeColumns(_ sender: Any?) {
        guard let id = targetColumns(from: sender).first, let index = controller.columnNames.index(of: id),
              index + 1 < controller.columnNames.count else { return }
        let right = controller.columnNames.ids[index + 1]
        DataFilePrompts.mergeSeparator(window: view.window) { [weak self] separator in
            guard let separator else { return }
            self?.controller.mergeColumn(id, with: right, separator: separator)
        }
    }

    @objc func dataFileSetColumnKind(_ sender: Any?) {
        guard let assignment = (sender as? NSMenuItem)?.representedObject as? DataFileKindAssignment else { return }
        controller.setKindOverride(assignment.kind, for: assignment.column)
    }

    @objc func dataFileShowStatistics(_ sender: Any?) {
        guard let id = targetColumns(from: sender).first else { return }
        showStatistics(for: id)
    }

    @objc func dataFileFillDown(_ sender: Any?) {
        guard let target = controller.cellTarget(explicitColumn: clickedColumn(from: sender)), target.keys.count > 1 else { return }
        controller.applyCleanup(.fillDown, columns: target.columns, keys: target.keys, actionName: String(localized: "Fill Down"))
    }

    @objc func dataFileSetCellsToValue(_ sender: Any?) {
        guard let target = controller.cellTarget(explicitColumn: clickedColumn(from: sender)) else { return }
        DataFilePrompts.value(window: view.window) { [weak self] value in
            guard let value else { return }
            self?.controller.applyCleanup(
                .setValue(value),
                columns: target.columns,
                keys: target.keys,
                actionName: String(localized: "Set Cells to Value")
            )
        }
    }

    @objc func dataFileTrimWhitespace(_ sender: Any?) {
        guard let target = controller.cellTarget(explicitColumn: clickedColumn(from: sender)) else { return }
        controller.applyCleanup(.trimWhitespace, columns: target.columns, keys: target.keys, actionName: String(localized: "Trim Whitespace"))
    }

    @objc func dataFileChangeCase(_ sender: Any?) {
        guard let style = (sender as? NSMenuItem)?.representedObject as? DataFileCaseAssignment,
              let target = controller.cellTarget(explicitColumn: style.column) else { return }
        controller.applyCleanup(
            .changeCase(style.style),
            columns: target.columns,
            keys: target.keys,
            actionName: String(localized: "Change Case")
        )
    }

    @objc func dataFileReplaceInColumn(_ sender: Any?) {
        guard let id = targetColumns(from: sender).first else { return }
        controller.scopeFind(to: id)
    }

    @objc func dataFileRemoveDuplicates(_ sender: Any?) {
        presentDuplicatesSheet()
    }

    @objc func dataFileShowProperties(_ sender: Any?) {
        presentPropertiesSheet()
    }

    @objc func exportQueryResults(_ sender: Any?) {
        presentExport()
    }

    @objc func dataFileImportIntoTable(_ sender: Any?) {
        presentImportIntoTable()
    }

    @objc func dataFileHideColumn(_ sender: Any?) {
        guard let id = targetColumns(from: sender).first, let name = controller.columnNames.name(for: id) else { return }
        controller.columnLayout.hiddenColumns.insert(name)
    }

    @objc func dataFileShowAllColumns(_ sender: Any?) {
        controller.columnLayout.hiddenColumns.removeAll()
    }

    @objc func dataFileCancelActivity(_ sender: Any?) {
        controller.cancelActivity()
    }

    func clickedColumn(from sender: Any?) -> TabularColumnID? {
        (sender as? NSMenuItem)?.representedObject as? TabularColumnID
    }

    func targetColumns(from sender: Any?) -> [TabularColumnID] {
        if let clicked = clickedColumn(from: sender) {
            let selected = controller.selectedColumnIDs()
            return selected.contains(clicked) ? selected : [clicked]
        }
        let selected = controller.selectedColumnIDs()
        if !selected.isEmpty {
            return selected
        }
        if let active = controller.activeCell() {
            return [active.column]
        }
        return []
    }

    private func anchorRow(from sender: Any?, below: Bool) -> Int? {
        if let clicked = (sender as? NSMenuItem)?.representedObject as? Int {
            return clicked
        }
        return below ? controller.selectedRowIndices.max() : controller.selectedRowIndices.min()
    }

    func validation(for action: Selector?) -> DataFileMenuValidation? {
        guard let action else { return nil }
        let editable = controller.isEditable && !controller.isBusy
        let loaded = controller.loadState == .loaded
        switch action {
        case #selector(dataFileAddColumn(_:)):
            return DataFileMenuValidation(isEnabled: editable)
        case #selector(addRow(_:)), #selector(dataFileInsertRowAbove(_:)), #selector(dataFileInsertRowBelow(_:)),
             #selector(dataFileInsertColumnLeft(_:)), #selector(dataFileInsertColumnRight(_:)):
            return DataFileMenuValidation(isEnabled: editable && !controller.columnNames.ids.isEmpty)
        case #selector(dataFileDeleteSelectedRows(_:)):
            return DataFileMenuValidation(isEnabled: editable && !controller.selectedRowIndices.isEmpty)
        case #selector(dataFileRenameColumn(_:)), #selector(dataFileDeleteColumn(_:)), #selector(dataFileSplitColumn(_:)),
             #selector(dataFileReplaceInColumn(_:)):
            return DataFileMenuValidation(isEnabled: editable && !targetColumns(from: nil).isEmpty)
        case #selector(dataFileMergeColumns(_:)):
            let index = targetColumns(from: nil).first.flatMap { controller.columnNames.index(of: $0) }
            return DataFileMenuValidation(isEnabled: editable && index.map { $0 + 1 < controller.columnNames.count } == true)
        case #selector(dataFileFillDown(_:)), #selector(dataFileSetCellsToValue(_:)), #selector(dataFileTrimWhitespace(_:)),
             #selector(dataFileChangeCase(_:)):
            return DataFileMenuValidation(isEnabled: editable && controller.cellTarget() != nil)
        case #selector(dataFileRemoveDuplicates(_:)):
            return DataFileMenuValidation(isEnabled: editable && controller.visibleRowCount > 1)
        case #selector(dataFileToggleHeaderRow(_:)):
            return DataFileMenuValidation(
                isEnabled: editable && controller.table?.source.intrinsicColumnNames == nil,
                state: controller.usesFirstRowAsHeader ? .on : .off
            )
        case #selector(dataFileShowProperties(_:)):
            return DataFileMenuValidation(isEnabled: loaded && controller.kind?.format == .delimited && !controller.isBusy)
        case #selector(dataFileShowStatistics(_:)), #selector(dataFileHideColumn(_:)):
            return DataFileMenuValidation(isEnabled: loaded && !targetColumns(from: nil).isEmpty)
        case #selector(dataFileShowAllColumns(_:)):
            return DataFileMenuValidation(isEnabled: !controller.columnLayout.hiddenColumns.isEmpty)
        case #selector(performFind(_:)), #selector(findNext(_:)), #selector(findPrevious(_:)),
             #selector(dataFileSearchAllColumns(_:)), #selector(exportQueryResults(_:)):
            return DataFileMenuValidation(isEnabled: loaded)
        case #selector(useSelectionForFind(_:)):
            return DataFileMenuValidation(isEnabled: loaded && controller.activeCell() != nil)
        case #selector(performFindAndReplace(_:)):
            return DataFileMenuValidation(isEnabled: editable)
        case #selector(dataFileImportIntoTable(_:)):
            return DataFileMenuValidation(isEnabled: loaded && DataFileImportTargets.hasConnectedSessions)
        case #selector(toggleFilterBar(_:)):
            return DataFileMenuValidation(
                isEnabled: loaded,
                title: controller.filterState.isVisible ? String(localized: "Hide Filters") : String(localized: "Show Filters")
            )
        case #selector(toggleInspector(_:)):
            return DataFileMenuValidation(
                isEnabled: loaded,
                title: controller.isInspectorVisible ? String(localized: "Hide Inspector") : String(localized: "Show Inspector")
            )
        case #selector(dataFileCancelActivity(_:)):
            return DataFileMenuValidation(isEnabled: controller.activity != nil)
        default:
            return nil
        }
    }
}

@MainActor
final class DataFileKindAssignment: NSObject {
    let column: TabularColumnID
    let kind: TabularInferredKind?

    init(column: TabularColumnID, kind: TabularInferredKind?) {
        self.column = column
        self.kind = kind
        super.init()
    }
}

@MainActor
final class DataFileCaseAssignment: NSObject {
    let column: TabularColumnID?
    let style: TabularCaseStyle

    init(column: TabularColumnID?, style: TabularCaseStyle) {
        self.column = column
        self.style = style
        super.init()
    }
}
