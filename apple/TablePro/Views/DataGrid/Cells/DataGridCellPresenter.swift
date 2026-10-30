//
//  DataGridCellPresenter.swift
//  TablePro
//

import AppKit
import TableProPluginKit

// Resolves what each drawn cell shows from the model, once per row draw rather than once per cell.
@MainActor
final class DataGridCellPresenter {
    struct Pass {
        let rows: TableRows
        let formats: [ValueDisplayFormat?]
        let selection: GridSelection
        let findMatch: GridFindState.Match?
        let isEditable: Bool
        let checkboxColumns: Set<Int>
        let marksEmptyText: Bool
        let palette: DataGridCellPalette
        let scope: ThemeScope
        let databaseType: DatabaseType?
        let showsInvisibleCharacters: Bool
        let nullDisplayString: String
    }

    private weak var model: DataGridModel?
    let registry: DataGridCellRegistry
    let renderer = DataGridCellRenderer()
    private let visualIndex = RowVisualIndex()
    private var visualIndexSource: ObjectIdentifier?
    private var highlightRuleSet = HighlightRuleSet.empty
    private var presentations: [Int: DataGridColumnPresentation] = [:]

    init(model: DataGridModel) {
        self.model = model
        registry = DataGridCellRegistry(scope: model.themeScope)
    }

    func adopt(_ model: DataGridModel) {
        self.model = model
        presentations.removeAll()
        visualIndexSource = nil
        highlightRuleSet = .empty
    }

    func makePass(in appearance: NSAppearance) -> Pass? {
        guard let model else { return nil }
        registry.preparePalette(in: appearance)
        let rows = model.rows
        prepareRowState(rows: rows)
        return Pass(
            rows: rows,
            formats: model.store.displayFormats,
            selection: model.selection,
            findMatch: model.find.currentMatch,
            isEditable: model.configuration.isEditable,
            checkboxColumns: model.configuration.checkboxColumns,
            marksEmptyText: model.configuration.marksEmptyText,
            palette: registry.palette,
            scope: model.themeScope,
            databaseType: model.configuration.traits.databaseType,
            showsInvisibleCharacters: registry.showsInvisibleCharacters,
            nullDisplayString: registry.nullDisplayString
        )
    }

    // MARK: - Row state

    func rebuildVisualIndex() {
        visualIndex.rebuild(from: model?.changeState)
        visualIndexSource = model?.changeState.map { ObjectIdentifier($0) }
    }

    func updateVisualIndex(for rowIDs: [RowID]) {
        let changeState = model?.changeState
        for rowID in rowIDs {
            visualIndex.updateRow(rowID, from: changeState)
        }
    }

    // Highlight rules and the change manager are read at draw time, so a row never paints with a stale tint.
    func prepareRowState(rows: TableRows) {
        syncHighlightRules(model?.dataSource?.gridHighlightRules ?? [], rows: rows)
        syncVisualIndexSource()
    }

    private func syncVisualIndexSource() {
        let source = model?.changeState.map { ObjectIdentifier($0) }
        guard source != visualIndexSource else { return }
        rebuildVisualIndex()
    }

    private func syncHighlightRules(_ rules: [HighlightRule], rows: TableRows) {
        let key = HighlightRuleSet.Key(rules: rules, columns: rows.columns, columnTypes: rows.columnTypes)
        if highlightRuleSet.key != key {
            highlightRuleSet = HighlightRuleSet(rules: rules, columns: rows.columns, columnTypes: rows.columnTypes)
        }
        guard let display = model?.display, display.highlightRuleSetKey != key else { return }
        display.highlightRuleSetKey = key
        display.cache.clearHighlights()
    }

    func visualState(of row: Row) -> RowVisualState {
        if let state = model?.dataSource?.gridVisualState(for: row.id) {
            return state
        }
        guard !visualIndex.isEmpty || !highlightRuleSet.isEmpty else { return .empty }
        return visualIndex.visualState(for: row.id).highlighted(highlight(for: row))
    }

    private func highlight(for row: Row) -> RowHighlight {
        guard !highlightRuleSet.isEmpty, let cache = model?.display.cache else { return .none }
        if let cached = cache.highlight(forID: row.id) { return cached }
        let resolved = highlightRuleSet.highlight(for: row.values)
        cache.setHighlight(resolved, forID: row.id)
        return resolved
    }

    // MARK: - Column presentation

    // The data indexes whose kind or accessory changed, so their auto widths can grow to fit.
    @discardableResult
    func refreshColumnPresentations() -> IndexSet {
        guard let model else { return [] }
        let rows = model.rows
        let configuration = model.configuration
        var next: [Int: DataGridColumnPresentation] = [:]
        next.reserveCapacity(rows.columns.count)
        var changed = IndexSet()
        for (dataIndex, name) in rows.columns.enumerated() {
            let type = dataIndex < rows.columnTypes.count ? rows.columnTypes[dataIndex] : nil
            let presentation = DataGridColumnPresentation.resolve(
                columnType: type,
                isForeignKey: rows.columnForeignKeys[name] != nil,
                isDropdown: configuration.dropdownColumns?.contains(dataIndex) == true,
                isTypePicker: configuration.typePickerColumns?.contains(dataIndex) == true,
                isEnumOrSet: Self.picksFromList(type: type, enumValues: rows.columnEnumValues[name]),
                isEditable: configuration.isEditable,
                isCheckbox: configuration.checkboxColumns.contains(dataIndex)
            )
            next[dataIndex] = presentation
            if presentations[dataIndex] != presentation {
                changed.insert(dataIndex)
            }
        }
        presentations = next
        return changed
    }

    func presentation(forDataIndex dataIndex: Int) -> DataGridColumnPresentation {
        presentations[dataIndex] ?? .plain
    }

    private static func picksFromList(type: ColumnType?, enumValues: [String]?) -> Bool {
        if type?.supportsElementEditing == true || type?.isVectorType == true { return true }
        guard let enumValues, !enumValues.isEmpty else { return false }
        return type?.isJsonType != true && type?.isBlobType != true && type?.isBooleanType != true
    }

    // Read by the accessibility cell, so a list a pointer can open has a role a screen reader can find.
    func presentsComboBox(dataIndex: Int) -> Bool {
        guard let configuration = model?.configuration, configuration.isEditable else { return false }
        return configuration.dropdownColumns?.contains(dataIndex) == true
            || configuration.typePickerColumns?.contains(dataIndex) == true
    }

    // MARK: - Text

    func displayText(of row: Row, dataIndex: Int, type: ColumnType?, pass: Pass) -> String {
        displayText(of: row, dataIndex: dataIndex, type: type, formats: pass.formats, databaseType: pass.databaseType, columnCount: pass.rows.columns.count)
    }

    func displayText(
        of row: Row,
        dataIndex: Int,
        type: ColumnType?,
        formats: [ValueDisplayFormat?],
        databaseType: DatabaseType?,
        columnCount: Int
    ) -> String {
        guard dataIndex >= 0, dataIndex < row.values.count, let cache = model?.display.cache else { return "" }
        let existing = cache.box(forID: row.id)
        if let existing, dataIndex < existing.values.count, let cached = existing.values[dataIndex] {
            return cached
        }
        let rawValue = row.values[dataIndex]
        let format = dataIndex < formats.count ? formats[dataIndex] : nil
        let formatted = CellDisplayFormatter.format(
            rawValue,
            columnType: type,
            displayFormat: format,
            databaseType: databaseType
        ) ?? rawValue.asText ?? ""

        let neededCount = max(dataIndex + 1, columnCount)
        let box: RowDisplayBox
        if let existing {
            box = existing
            if box.values.count < neededCount {
                box.values.append(contentsOf: repeatElement(String?.none, count: neededCount - box.values.count))
            }
        } else {
            box = RowDisplayBox(ContiguousArray<String?>(repeating: nil, count: neededCount))
        }
        box.values[dataIndex] = formatted
        cache.setBox(box, forID: row.id)
        return formatted
    }

    // Formats a whole row ahead of the viewport, for the background prewarm.
    func cacheText(of row: Row, rows: TableRows, formats: [ValueDisplayFormat?], databaseType: DatabaseType?) {
        guard let cache = model?.display.cache, cache.box(forID: row.id) == nil else { return }
        let columnCount = rows.columns.count
        var values = ContiguousArray<String?>(repeating: nil, count: columnCount)
        for dataIndex in 0..<min(row.values.count, columnCount) {
            let type = dataIndex < rows.columnTypes.count ? rows.columnTypes[dataIndex] : nil
            let format = dataIndex < formats.count ? formats[dataIndex] : nil
            values[dataIndex] = CellDisplayFormatter.format(
                row.values[dataIndex],
                columnType: type,
                displayFormat: format,
                databaseType: databaseType
            ) ?? row.values[dataIndex].asText ?? ""
        }
        cache.setBox(RowDisplayBox(values), forID: row.id)
    }

    // MARK: - Appearance

    func appearance(
        of row: Row,
        displayRow: Int,
        column: DataGridColumn,
        visualState: RowVisualState,
        pass: Pass,
        onEmphasizedSelection: Bool
    ) -> DataGridCellAppearance? {
        let dataIndex = column.dataIndex
        guard dataIndex >= 0, dataIndex < row.values.count else { return nil }
        let rawValue = row.values[dataIndex]
        let text = displayText(of: row, dataIndex: dataIndex, type: column.type, pass: pass)
        let isFindMatch = pass.findMatch.map { $0.rowID == row.id && $0.columnID == column.id } ?? false

        return DataGridCellAppearance.resolve(
            kind: presentation(forDataIndex: dataIndex).kind,
            content: DataGridCellContent(
                displayText: text,
                rawValue: rawValue.asText,
                placeholder: DataGridCellContent.placeholder(
                    for: rawValue,
                    isAbsent: row.isAbsent(dataIndex),
                    unloadedByteCount: row.unloadedByteCount(dataIndex),
                    marksEmptyText: pass.marksEmptyText
                )
            ),
            state: DataGridCellState(
                visualState: visualState,
                isEditable: pass.isEditable,
                isCurrentFindMatch: isFindMatch,
                row: displayRow,
                columnIndex: dataIndex
            ),
            palette: pass.palette,
            nullDisplayString: pass.nullDisplayString,
            onEmphasizedSelection: onEmphasizedSelection,
            checkboxMark: checkboxMark(of: row, column: column, checkboxColumns: pass.checkboxColumns),
            textTone: model?.dataSource?.gridTextTone(for: row.id, column: column),
            revealsInvisibleCharacters: pass.showsInvisibleCharacters
        )
    }

    func checkboxMark(of row: Row, column: DataGridColumn, checkboxColumns: Set<Int>) -> DataGridCheckboxMark? {
        guard checkboxColumns.contains(column.dataIndex),
              let isOn = model?.dataSource?.gridCheckboxState(for: row.id, column: column) else { return nil }
        return isOn ? .checked : .unchecked
    }

    // A placeholder announces itself by name rather than as the italic marker a sighted reader sees.
    func accessibilityText(of row: Row, column: DataGridColumn) -> String {
        guard let model else { return "" }
        if let spoken = model.dataSource?.gridAccessibilityText(for: row.id, column: column) {
            return spoken
        }
        let dataIndex = column.dataIndex
        guard dataIndex >= 0, dataIndex < row.values.count else { return "" }
        let rows = model.rows
        let text = displayText(
            of: row,
            dataIndex: dataIndex,
            type: column.type,
            formats: model.store.displayFormats,
            databaseType: model.configuration.traits.databaseType,
            columnCount: rows.columns.count
        )
        let rawValue = row.values[dataIndex]
        switch DataGridCellContent.placeholder(
            for: rawValue,
            isAbsent: row.isAbsent(dataIndex),
            unloadedByteCount: row.unloadedByteCount(dataIndex),
            marksEmptyText: model.configuration.marksEmptyText
        ) {
        case .null: return String(localized: "NULL")
        case .empty: return String(localized: "Empty")
        case .defaultMarker: return String(localized: "DEFAULT")
        case .absent: return DataGridCellContent.absentFieldText
        case .unloaded(let byteCount): return DataGridCellContent.unloadedSpokenText(byteCount: byteCount)
        case .none: return spokenText(of: text)
        }
    }

    // A mark drawn in the cell is read by its name, or VoiceOver says nothing for it.
    private func spokenText(of text: String) -> String {
        guard registry.showsInvisibleCharacters else { return text }
        let revealed = RevealedText(text, marksLineBreaks: true)
        return revealed.revealsAnyCharacter ? revealed.spokenText : text
    }

    func pendingChangeDescription(of row: Row, dataIndex: Int) -> String? {
        DataGridCellTextMark.accessibilityDescription(state: visualState(of: row), columnIndex: dataIndex)
    }

    func highlightDescription(of row: Row, dataIndex: Int) -> String? {
        guard let rule = visualState(of: row).drawnHighlightRule(forColumn: dataIndex) else { return nil }
        return HighlightRuleDescription.condition(of: rule, valueLimit: HighlightRuleDescription.menuValueLimit)
    }
}
