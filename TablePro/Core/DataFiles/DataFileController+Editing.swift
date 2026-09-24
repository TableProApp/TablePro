//
//  DataFileController+Editing.swift
//  TablePro
//

import Foundation
import TableProTabular
import TableProTabularIO

extension DataFileController {
    func editedCell(_ text: String, replacing original: TabularCell, column id: TabularColumnID) -> TabularCell {
        guard kind?.holdsNull == true else { return .text(text) }
        return TabularCell(kind: Self.jsonKind(for: text, replacing: original.kind, columnKind: kind(of: id)), text: text)
    }

    var nullCell: TabularCell {
        (kind?.holdsNull ?? false) ? TabularCell(kind: .null, text: "null") : .text("")
    }

    nonisolated static func jsonKind(
        for text: String,
        replacing original: TabularCellKind,
        columnKind: TabularInferredKind
    ) -> TabularCellKind {
        switch original {
        case .null, .missing:
            return jsonKind(forNewValue: text, columnKind: columnKind)
        case .object, .array:
            return (try? JSONValueTyping.literal(for: text, originalKind: original)) == nil ? .text : original
        case .number, .boolean, .text, .error, .date:
            return original
        }
    }

    nonisolated static func jsonKind(forNewValue text: String, columnKind: TabularInferredKind) -> TabularCellKind {
        guard text != "null" else { return .null }
        switch columnKind {
        case .integer, .decimal:
            return JSONValueTyping.isNumberLexeme(text) ? .number : .text
        case .boolean:
            return text == "true" || text == "false" ? .boolean : .text
        case .date, .text:
            return .text
        }
    }

    func setCell(pageRow: Int, column: Int, text: String?) {
        guard isEditable, let table, let key = key(forPageRow: pageRow),
              columnNames.ids.indices.contains(column) else { return }
        let id = columnNames.ids[column]
        guard let tabularColumn = table.column(id) else { return }
        let original = table.cell(key: key, column: tabularColumn)
        let cell = text.map { editedCell($0, replacing: original, column: id) } ?? nullCell
        guard cell != original else { return }
        var updated = table
        updated.setCells([(key: key, columnID: id, cell: cell)])
        commit(updated, actionName: String(localized: "Edit Cell"))
    }

    func blankRow() -> [TabularCell] {
        guard let table else { return [] }
        return Array(repeating: table.source.absentCell, count: table.columnCount)
    }

    func appendRow() {
        guard isEditable, var updated = table else { return }
        let keys = updated.insertRows([blankRow()], at: updated.rowCount)
        commitInsertedRows(updated, keys: keys, displayAnchor: nil, below: true)
    }

    func insertRow(anchoredAtPageRow pageRow: Int?, below: Bool) {
        guard isEditable, var updated = table else { return }
        let anchorKey = pageRow.flatMap { key(forPageRow: $0) }
        let logicalAnchor = anchorKey.flatMap { logicalRow(forKey: $0) }
        let insertion = logicalAnchor.map { below ? $0 + 1 : $0 } ?? (below ? updated.rowCount : 0)
        let keys = updated.insertRows([blankRow()], at: insertion)
        commitInsertedRows(updated, keys: keys, displayAnchor: anchorKey, below: below)
    }

    private func commitInsertedRows(_ updated: TabularTable, keys: [Int], displayAnchor: Int?, below: Bool) {
        var newDisplay = displayKeys
        if var current = newDisplay {
            if let anchor = displayAnchor, let position = current.firstIndex(of: anchor) {
                current.insert(contentsOf: keys, at: below ? position + 1 : position)
            } else {
                current.append(contentsOf: keys)
            }
            newDisplay = current
        }
        commit(updated, actionName: String(localized: "Insert Row"), displayKeys: .some(newDisplay))
        if let first = keys.first {
            reveal(key: first)
        }
    }

    func deleteRows(pageRows: Set<Int>) -> [Int] {
        let keys = pageRows.sorted().compactMap { key(forPageRow: $0) }
        guard isEditable, !keys.isEmpty, var updated = table else { return [] }
        let removed = Set(keys)
        updated.deleteRows(keys: removed)
        let newDisplay = displayKeys.map { $0.filter { !removed.contains($0) } }
        commit(
            updated,
            actionName: keys.count == 1 ? String(localized: "Delete Row") : String(localized: "Delete Rows"),
            displayKeys: .some(newDisplay)
        )
        return keys
    }

    func rowsHaveData(pageRows: Set<Int>) -> Bool {
        guard let table else { return false }
        let keys = pageRows.compactMap { key(forPageRow: $0) }
        var hasData = false
        table.scan(columns: columnNames.ids, keys: keys) { _, cells in
            for index in 0..<cells.count where !cells.bytes[index].isEmpty {
                hasData = true
                return false
            }
            return true
        }
        return hasData
    }

    func pasteRows(_ rows: [[String]]) {
        guard isEditable, !rows.isEmpty, var updated = table else { return }
        let widest = rows.map(\.count).max() ?? 0
        let existing = updated.columnCount
        if widest > existing {
            for index in existing..<widest {
                updated.insertColumn(named: "", at: index)
            }
        }
        let absent = updated.source.absentCell
        let ids = updated.columnIDs
        let cells = rows.map { row in
            (0..<updated.columnCount).map { column in
                column < row.count ? editedCell(row[column], replacing: absent, column: ids[column]) : absent
            }
        }
        let keys = updated.insertRows(cells, at: updated.rowCount)
        var newDisplay = displayKeys
        newDisplay?.append(contentsOf: keys)
        commit(updated, actionName: String(localized: "Paste"), displayKeys: .some(newDisplay))
        if let first = keys.first {
            reveal(key: first)
        }
    }

    func insertColumn(named name: String, at index: Int) {
        guard isEditable, var updated = table else { return }
        let clamped = min(max(0, index), updated.columnCount)
        let id = updated.insertColumn(named: name, at: clamped)
        commit(updated, actionName: String(localized: "Insert Column")) { controller in
            controller.setInferredKind(.text, for: id)
        }
    }

    func deleteColumns(_ ids: Set<TabularColumnID>) {
        guard isEditable, !ids.isEmpty, var updated = table else { return }
        let removedNames = ids.compactMap { columnNames.name(for: $0) }
        updated.deleteColumns(ids)
        let referencedFilters = filterState.filters.contains { removedNames.contains($0.columnName) }
        let referencedSort = sortReferences.contains { ids.contains($0.column) }
        commit(
            updated,
            actionName: ids.count == 1 ? String(localized: "Delete Column") : String(localized: "Delete Columns"),
            includesFilters: referencedFilters
        ) { controller in
            controller.columnLayout.hiddenColumns.subtract(removedNames)
            controller.filterState.filters.removeAll { removedNames.contains($0.columnName) }
        }
        if referencedFilters || referencedSort {
            runQuery()
        }
    }

    func renameColumn(_ id: TabularColumnID, to name: String) {
        guard isEditable, var updated = table, let oldName = columnNames.name(for: id) else { return }
        if updated.headerRowKey == nil, updated.source.intrinsicColumnNames == nil {
            adoptDisplayNamesAsHeader(in: &updated)
        }
        updated.renameColumn(id, to: name)
        let referencedFilters = filterState.filters.contains { $0.columnName == oldName }
        commit(updated, actionName: String(localized: "Rename Column"), includesFilters: referencedFilters) { controller in
            guard let newName = controller.columnNames.name(for: id), newName != oldName else { return }
            for index in controller.filterState.filters.indices
                where controller.filterState.filters[index].columnName == oldName {
                controller.filterState.filters[index].columnName = newName
            }
            if controller.columnLayout.hiddenColumns.remove(oldName) != nil {
                controller.columnLayout.hiddenColumns.insert(newName)
            }
        }
    }

    private func adoptDisplayNamesAsHeader(in table: inout TabularTable) {
        table.insertRows([columnNames.displayNames.map { TabularCell.text($0) }], at: 0)
        table.setUsesFirstRowAsHeader(true)
    }

    func setUsesFirstRowAsHeader(_ enabled: Bool) {
        guard isEditable, var updated = table, updated.source.intrinsicColumnNames == nil else { return }
        guard (updated.headerRowKey != nil) != enabled else { return }
        updated.setUsesFirstRowAsHeader(enabled)
        commit(updated, actionName: String(localized: "Toggle Header Row"), displayKeys: .some(nil))
        if let dialect, dialect.hasHeaderRow != enabled {
            var changed = dialect
            changed.hasHeaderRow = enabled
            setDialect(changed)
        }
        runQuery()
    }

    var usesFirstRowAsHeader: Bool {
        table?.headerRowKey != nil
    }

    func setKindOverride(_ kind: TabularInferredKind?, for id: TabularColumnID) {
        if let kind {
            kindOverrides[id] = kind
        } else {
            kindOverrides[id] = nil
        }
        if sortState.isSorting || !filterState.appliedFilters.isEmpty {
            runQuery()
        }
    }
}
