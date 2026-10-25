import Foundation
import TableProPluginKit

struct StructureSortDescriptor {
    let column: Int
    let ascending: Bool
}

@MainActor
final class StructureRowProvider {
    private static let canonicalFieldOrder: [StructureColumnField] = [
        .name, .type, .nullable, .defaultValue, .onUpdate, .generated, .generationExpression,
        .primaryKey, .autoIncrement, .comment, .charset, .collation
    ]

    private static let booleanFields: [StructureColumnField] = [
        .nullable, .primaryKey, .autoIncrement, .onUpdate
    ]

    private let changeManager: StructureChangeManager
    private let tab: StructureTab
    private let databaseType: DatabaseType
    private let additionalFields: Set<StructureColumnField>
    private let serverSupport: StructureServerSupport
    let orderedColumnFields: [StructureColumnField]
    private let filterText: String?
    private let sortDescriptor: StructureSortDescriptor?

    private let cachedRows: [IndexedRow]

    var filteredToSourceMap: [Int] {
        cachedRows.map { $0.sourceIndex }
    }

    var rows: [[String?]] {
        cachedRows.map { $0.row }
    }

    var columns: [String] {
        switch tab {
        case .columns:
            return orderedColumnFields.map { $0.displayName }
        case .indexes:
            return [
                String(localized: "Name"),
                String(localized: "Columns"),
                String(localized: "Type"),
                String(localized: "Unique"),
                String(localized: "Condition")
            ]
        case .foreignKeys:
            return [
                String(localized: "Name"),
                String(localized: "Columns"),
                String(localized: "Ref Table"),
                String(localized: "Ref Columns"),
                String(localized: "Ref Schema"),
                String(localized: "On Delete"),
                String(localized: "On Update")
            ]
        case .checkConstraints:
            return [
                String(localized: "Name"),
                String(localized: "Expression"),
                String(localized: "Columns")
            ]
        case .ddl, .parts, .triggers:
            return []
        }
    }

    var columnTypes: [ColumnType] {
        Array(repeating: .text(rawType: nil), count: columns.count)
    }

    var dropdownColumns: Set<Int> {
        Set(customDropdownOptions.keys).union(rowDependentDropdownColumns)
    }

    var rowDependentDropdownColumns: Set<Int> {
        switch tab {
        case .foreignKeys: ForeignKeyReferenceMenus.rowDependentColumns
        case .indexes: [Self.indexTypeColumn]
        case .columns, .checkConstraints, .ddl, .parts, .triggers: []
        }
    }

    static let indexTypeColumn = 2

    static func indexMenuOptions(
        columnIndex: Int,
        index: EditableIndexDefinition,
        serverSupport: StructureServerSupport
    ) -> [GridMenuOption]? {
        guard columnIndex == indexTypeColumn else { return nil }
        return GridMenuOption.values(serverSupport.indexTypeChoices(keeping: index.type).map(\.rawValue))
    }

    var customDropdownOptions: [Int: [GridMenuOption]] {
        switch tab {
        case .foreignKeys:
            let dialect = ForeignKeyDialect.forType(databaseType)
            let deleteActions = dialect.deleteActions.isEmpty ? [.noAction] : dialect.deleteActions
            let updateActions = dialect.updateActions.isEmpty ? [.noAction] : dialect.updateActions
            return [
                5: GridMenuOption.values(deleteActions.map(\.rawValue)),
                6: GridMenuOption.values(updateActions.map(\.rawValue))
            ]
        case .indexes:
            return [3: GridMenuOption.values(Self.booleanOptions)]
        case .columns:
            var result: [Int: [GridMenuOption]] = [:]
            for field in Self.booleanFields {
                guard let index = orderedColumnFields.firstIndex(of: field) else { continue }
                result[index] = GridMenuOption.values(Self.booleanOptions)
            }
            if let index = orderedColumnFields.firstIndex(of: .generated) {
                result[index] = GridMenuOption.values(Self.generationOptions)
            }
            if let index = orderedColumnFields.firstIndex(of: .defaultValue) {
                result[index] = ColumnDefaultVocabulary.options(for: databaseType)
            }
            return result
        case .checkConstraints, .ddl, .parts, .triggers:
            return [:]
        }
    }


    static let booleanOptions = ["YES", "NO"]

    static let notGeneratedOption = String(localized: "Not generated")

    static let generationOptions = [notGeneratedOption] + GenerationKind.allCases.map(\.rawValue)

    var typePickerColumns: Set<Int> {
        switch tab {
        case .columns:
            if let i = orderedColumnFields.firstIndex(of: .type) { return [i] }
            return []
        case .indexes, .foreignKeys, .checkConstraints, .ddl, .parts, .triggers:
            return []
        }
    }

    var totalRowCount: Int {
        cachedRows.count
    }

    init(
        changeManager: StructureChangeManager,
        tab: StructureTab,
        databaseType: DatabaseType = .mysql,
        additionalFields: Set<StructureColumnField> = [],
        serverSupport: StructureServerSupport,
        filterText: String? = nil,
        sortDescriptor: StructureSortDescriptor? = nil
    ) {
        self.changeManager = changeManager
        self.tab = tab
        self.databaseType = databaseType
        self.additionalFields = additionalFields
        self.serverSupport = serverSupport
        self.filterText = filterText
        self.sortDescriptor = sortDescriptor
        self.orderedColumnFields = Self.orderedFields(
            for: databaseType,
            additionalFields: additionalFields,
            serverSupport: serverSupport
        )

        let allRows = Self.buildAllRows(
            tab: tab, changeManager: changeManager, orderedColumnFields: self.orderedColumnFields
        )
        self.cachedRows = Self.applyFilterAndSort(
            allRows, filterText: filterText, sortDescriptor: sortDescriptor
        )
    }

    static func orderedFields(
        for databaseType: DatabaseType,
        additionalFields: Set<StructureColumnField> = [],
        serverSupport: StructureServerSupport
    ) -> [StructureColumnField] {
        let pluginFields = Set(PluginManager.shared.structureColumnFields(for: databaseType))
        let fields = pluginFields.union(additionalFields)
        return canonicalFieldOrder.filter { fields.contains($0) && serverSupport.offers($0) }
    }

    // MARK: - Row Access

    func row(at index: Int) -> [String?]? {
        guard index >= 0, index < cachedRows.count else { return nil }
        return cachedRows[index].row
    }

    func sourceIndex(atDisplay displayRow: Int) -> Int? {
        guard displayRow >= 0, displayRow < cachedRows.count else { return nil }
        return cachedRows[displayRow].sourceIndex
    }

    func modifiedFieldIndices(atDisplay displayRow: Int) -> Set<Int> {
        guard let sourceIndex = sourceIndex(atDisplay: displayRow),
              let working = row(at: displayRow),
              let original = originalRow(atSource: sourceIndex) else { return [] }
        return Set(working.indices.filter { index in
            let originalValue = index < original.count ? original[index] : nil
            return working[index] != originalValue
        })
    }

    func isPendingDelete(atDisplay displayRow: Int) -> Bool {
        guard let sourceIndex = sourceIndex(atDisplay: displayRow) else { return false }
        return changeManager.deleteInsertState(for: sourceIndex, tab: tab).isDeleted
    }

    private func originalRow(atSource sourceIndex: Int) -> [String?]? {
        switch tab {
        case .columns:
            guard sourceIndex < changeManager.workingColumns.count else { return nil }
            let id = changeManager.workingColumns[sourceIndex].id
            guard let original = changeManager.currentColumns.first(where: { $0.id == id }) else { return nil }
            return Self.row(for: original, orderedColumnFields: orderedColumnFields)
        case .indexes:
            guard sourceIndex < changeManager.workingIndexes.count else { return nil }
            let id = changeManager.workingIndexes[sourceIndex].id
            guard let original = changeManager.currentIndexes.first(where: { $0.id == id }) else { return nil }
            return Self.row(for: original)
        case .foreignKeys:
            guard sourceIndex < changeManager.workingForeignKeys.count else { return nil }
            let id = changeManager.workingForeignKeys[sourceIndex].id
            guard let original = changeManager.currentForeignKeys.first(where: { $0.id == id }) else { return nil }
            return Self.row(for: original)
        case .checkConstraints:
            guard sourceIndex < changeManager.workingCheckConstraints.count else { return nil }
            let id = changeManager.workingCheckConstraints[sourceIndex].id
            guard let original = changeManager.currentCheckConstraints.first(where: { $0.id == id }) else {
                return nil
            }
            return Self.row(for: original)
        case .ddl, .parts, .triggers:
            return nil
        }
    }

    // MARK: - Private Helpers

    private struct IndexedRow {
        let sourceIndex: Int
        let row: [String?]
    }

    private static func buildAllRows(
        tab: StructureTab,
        changeManager: StructureChangeManager,
        orderedColumnFields: [StructureColumnField]
    ) -> [IndexedRow] {
        switch tab {
        case .columns:
            return changeManager.workingColumns.enumerated().map { index, column in
                IndexedRow(sourceIndex: index, row: row(for: column, orderedColumnFields: orderedColumnFields))
            }
        case .indexes:
            return changeManager.workingIndexes.enumerated().map { index, indexInfo in
                IndexedRow(sourceIndex: index, row: row(for: indexInfo))
            }
        case .foreignKeys:
            return changeManager.workingForeignKeys.enumerated().map { index, fk in
                IndexedRow(sourceIndex: index, row: row(for: fk))
            }
        case .checkConstraints:
            return changeManager.workingCheckConstraints.enumerated().map { index, constraint in
                IndexedRow(sourceIndex: index, row: row(for: constraint))
            }
        case .ddl, .parts, .triggers:
            return []
        }
    }

    private static func row(for constraint: EditableCheckConstraintDefinition) -> [String?] {
        [
            constraint.name,
            constraint.expression,
            constraint.columns.joined(separator: ", ")
        ]
    }

    private static func row(
        for column: EditableColumnDefinition,
        orderedColumnFields: [StructureColumnField]
    ) -> [String?] {
        orderedColumnFields.map { field -> String? in
            switch field {
            case .name: column.name
            case .type: column.dataType
            case .nullable: column.isNullable ? "YES" : "NO"
            case .defaultValue: column.defaultValue ?? ""
            case .onUpdate: column.onUpdate != nil ? "YES" : "NO"
            case .primaryKey: column.isPrimaryKey ? "YES" : "NO"
            case .autoIncrement: column.autoIncrement ? "YES" : "NO"
            case .comment: column.comment ?? ""
            case .charset: column.charset ?? ""
            case .collation: column.collation ?? ""
            case .generated: column.generationKind?.rawValue ?? Self.notGeneratedOption
            case .generationExpression: column.generationExpression ?? ""
            @unknown default: nil
            }
        }
    }

    private static func row(for index: EditableIndexDefinition) -> [String?] {
        let columnsStr = index.columns.map { col in
            if let prefix = index.columnPrefixes[col] {
                return "\(col)(\(prefix))"
            }
            return col
        }.joined(separator: ", ")
        return [
            index.name,
            columnsStr,
            index.type.rawValue,
            index.isUnique ? "YES" : "NO",
            index.whereClause ?? ""
        ]
    }

    private static func row(for fk: EditableForeignKeyDefinition) -> [String?] {
        [
            fk.name,
            fk.columns.joined(separator: ", "),
            fk.referencedTable,
            fk.referencedColumns.joined(separator: ", "),
            fk.referencedSchema ?? "",
            fk.onDelete.rawValue,
            fk.onUpdate.rawValue
        ]
    }

    private static func applyFilterAndSort(
        _ rows: [IndexedRow],
        filterText: String?,
        sortDescriptor: StructureSortDescriptor?
    ) -> [IndexedRow] {
        var result = rows

        if let filterText, !filterText.isEmpty {
            result = result.filter { indexed in
                guard let name = indexed.row.first ?? nil else { return false }
                return name.localizedCaseInsensitiveContains(filterText)
            }
        }

        if let sortDescriptor, sortDescriptor.column >= 0 {
            result.sort { a, b in
                let aVal = (sortDescriptor.column < a.row.count ? a.row[sortDescriptor.column] : nil) ?? ""
                let bVal = (sortDescriptor.column < b.row.count ? b.row[sortDescriptor.column] : nil) ?? ""
                let comparison = aVal.localizedStandardCompare(bVal)
                return sortDescriptor.ascending ? comparison == .orderedAscending : comparison == .orderedDescending
            }
        }

        return result
    }
}

extension StructureRowProvider {
    // A row is named by its index in the working list, so a search, a sort or the grid's value filter
    // never changes which definition an edit lands on.
    static func rowID(forSourceIndex index: Int) -> RowID {
        .existing(index)
    }

    static func sourceIndex(of rowID: RowID) -> Int? {
        guard case .existing(let index) = rowID, index >= 0 else { return nil }
        return index
    }

    func displayRow(ofSourceIndex sourceIndex: Int) -> Int? {
        cachedRows.firstIndex { $0.sourceIndex == sourceIndex }
    }

    func asTableRows() -> TableRows {
        var rows = ContiguousArray<Row>()
        rows.reserveCapacity(cachedRows.count)
        for indexed in cachedRows {
            rows.append(Row(
                id: Self.rowID(forSourceIndex: indexed.sourceIndex),
                values: ContiguousArray(indexed.row.map(PluginCellValue.fromOptional))
            ))
        }
        return TableRows(
            rows: rows,
            columns: columns,
            columnTypes: columnTypes,
            columnNullable: Dictionary(uniqueKeysWithValues: columns.map { ($0, false) })
        )
    }
}
