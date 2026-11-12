//
//  TableRows.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct TableRows: Sendable {
    var rows: ContiguousArray<Row>
    private(set) var indexByID: [RowID: Int]
    var columns: [String]
    var columnTypes: [ColumnType]
    var columnDefaults: [String: String?]
    var columnForeignKeys: [String: ForeignKeyInfo]
    var columnEnumValues: [String: [String]]
    var columnNullable: [String: Bool]
    var columnComments: [String: String]
    var columnIdentity: [String: IdentityKind]
    // A result set can drop the length (MySQL types `CHAR(32)` as `CHAR`), so the schema's spelling is kept beside it.
    var columnDeclaredTypes: [String: String]
    /// Columns the app must never write. Held here as well as on `DataChangeManager` because the
    /// change manager is rebuilt by `configureForTable` on every execution and only the schema
    /// fetch refills it, so a rerun that answered from cache left a generated or `GENERATED ALWAYS
    /// AS IDENTITY` column writable again.
    var generatedColumns: Set<String>
    var rowMatchPolicy: RowMatchPolicy
    /// Whether the sets above came from the table's own schema. A result set reports far less than
    /// the schema does, so a command that stages a value from them waits rather than reading an
    /// empty set as "this table owns nothing".
    var hasAuthoritativeSchema: Bool
    var foreignKeysFetched: Bool
    /// What the driver finds each fetched row by again, keyed by row identity so a sort, a value
    /// filter or a removal cannot pair a row with another row's document. Only a driver that edits
    /// whole documents fills it, and a row with none cannot be edited that way.
    private(set) var rowLocators: [RowID: String] = [:]
    /// The masking rules matched to these columns. Every fetched value is written through it, and a
    /// masked column never takes an edit, so no reader can see the stored value.
    private(set) var masks: ColumnMasks = .none
    private var exportPolicy: MaskingPolicy = .none
    private var exportTable: String?
    private var reportedOrigins: (columns: [String], origins: [PluginColumnOrigin?])?

    // What the driver said each column reads, while the columns are still the ones it said it for.
    var columnOrigins: [PluginColumnOrigin?]? {
        guard let reportedOrigins, reportedOrigins.columns == columns else { return nil }
        return reportedOrigins.origins
    }

    var maskedColumnNames: Set<String> {
        Set(masks.maskedColumns.compactMap { columns.indices.contains($0) ? columns[$0] : nil })
    }

    init(
        rows: ContiguousArray<Row> = [],
        columns: [String] = [],
        columnTypes: [ColumnType] = [],
        columnDefaults: [String: String?] = [:],
        columnForeignKeys: [String: ForeignKeyInfo] = [:],
        columnEnumValues: [String: [String]] = [:],
        columnNullable: [String: Bool] = [:],
        columnComments: [String: String] = [:],
        columnIdentity: [String: IdentityKind] = [:],
        columnDeclaredTypes: [String: String] = [:],
        generatedColumns: Set<String> = [],
        rowMatchPolicy: RowMatchPolicy = .none,
        hasAuthoritativeSchema: Bool = false,
        foreignKeysFetched: Bool = false
    ) {
        self.rows = rows
        self.indexByID = Self.buildIndex(for: rows)
        self.columns = columns
        self.columnTypes = columnTypes
        self.columnDefaults = columnDefaults
        self.columnForeignKeys = columnForeignKeys
        self.columnEnumValues = columnEnumValues
        self.columnNullable = columnNullable
        self.columnComments = columnComments
        self.columnIdentity = columnIdentity
        self.columnDeclaredTypes = columnDeclaredTypes
        self.generatedColumns = generatedColumns
        self.rowMatchPolicy = rowMatchPolicy
        self.hasAuthoritativeSchema = hasAuthoritativeSchema
        self.foreignKeysFetched = foreignKeysFetched
    }

    var count: Int { rows.count }

    /// The type each column was read as, by name. A name the result repeats keeps the first column's type, the one a
    /// save addresses by that name, and a column the driver named no type for is left out.
    var columnTypeNames: [String: String] {
        var names: [String: String] = [:]
        var seen: Set<String> = []
        for (index, column) in columns.enumerated() where seen.insert(column).inserted {
            guard columnTypes.indices.contains(index), let rawType = columnTypes[index].rawType else { continue }
            names[column] = rawType
        }
        return names
    }

    /// Whether leaving the column out of an INSERT makes the server supply the value.
    ///
    /// A default expression is only one of the two ways that happens. An identity column has no
    /// default at all: PostgreSQL reports the generation in `pg_attribute.attidentity` and leaves
    /// `column_default` null, so asking about the default alone answers "no" for every identity
    /// column and the new row goes out carrying NULL.
    ///
    /// A default of NULL is not one of them. The value is already known, so sending it gives the
    /// same row, and it keeps working on a MySQL column whose default was dropped, which the catalog
    /// reports exactly like `DEFAULT NULL` but which fails an INSERT that leaves it out.
    func serverAssignsValue(forColumn name: String) -> Bool {
        if columnIdentity[name] != nil { return true }
        guard let defaultValue = columnDefaults[name] ?? nil else { return false }
        return !ColumnDefaultLiteral.isNull(defaultValue)
    }

    /// The column's type with the labels its catalog declared, which a result set alone never carries.
    func editingColumnType(at index: Int) -> ColumnType? {
        guard columnTypes.indices.contains(index) else { return nil }
        let columnType = columnTypes[index]
        guard columns.indices.contains(index),
              let labels = columnEnumValues[columns[index]], !labels.isEmpty else { return columnType }
        return columnType.withAllowedValues(labels)
    }

    func declaredType(at index: Int) -> String? {
        columns.indices.contains(index) ? columnDeclaredTypes[columns[index]] : nil
    }

    /// What text entered for a column stages, or nil when the column holds neither it nor NULL.
    ///
    /// An emptied date in a NOT NULL column has no value to write. MySQL turns NULL there into the
    /// current time when `explicit_defaults_for_timestamp` is off, and `''` into the zero date, so
    /// the edit is refused rather than staged.
    func enteredValue(_ text: String?, forColumn index: Int) -> PluginCellValue? {
        let value = PluginCellValue.entered(text, columnType: editingColumnType(at: index))
        guard value.isNull, refusesNull(columnAt: index) else { return value }
        return nil
    }

    func refusesNull(columnAt index: Int) -> Bool {
        columns.indices.contains(index) && columnNullable[columns[index]] == false
    }

    func value(at row: Int, column: Int) -> PluginCellValue {
        guard row >= 0, row < rows.count else { return .null }
        return rows[row][column]
    }

    func isAbsent(row: Int, column: Int) -> Bool {
        guard row >= 0, row < rows.count else { return false }
        return rows[row].isAbsent(column)
    }

    func unloadedByteCount(row: Int, column: Int) -> Int? {
        guard row >= 0, row < rows.count else { return nil }
        return rows[row].unloadedByteCount(column)
    }

    var hasUnloadedValues: Bool {
        rows.contains { $0.hasUnloadedValues }
    }

    /// Masks the held values of every column `incoming` adds. A column already masked keeps its mask, since the
    /// value under it is gone until the next fetch.
    @discardableResult
    mutating func addMasks(_ incoming: ColumnMasks, policy: MaskingPolicy? = nil, table: String? = nil) -> Delta {
        if let policy {
            exportPolicy = policy
            exportTable = table
        }
        let added = incoming.styles.filter { column, _ in column < columns.count && !masks.isMasked(column) }
        guard !added.isEmpty || policy != nil else { return .none }
        let addedMasks = ColumnMasks(styles: added)
        for index in rows.indices {
            for column in added.keys where column < rows[index].values.count {
                rows[index].values[column] = addedMasks.value(rows[index].values[column], column: column)
            }
            if var snapshot = rows[index].exportSnapshot {
                let masked = Self.maskedFields(in: snapshot.document, columns: columns, masks: addedMasks, policy: exportPolicy, table: exportTable)
                snapshot.document = ExportDocumentMasking.document(
                    snapshot.document, columns: columns, masks: addedMasks, policy: exportPolicy,
                    table: exportTable, excluding: snapshot.maskedFields, row: Array(snapshot.values)
                )
                snapshot.maskedFields.formUnion(masked)
                snapshot.values = ContiguousArray(addedMasks.row(Array(snapshot.values)))
                rows[index].exportSnapshot = snapshot
            }
        }
        masks = ColumnMasks(styles: masks.styles.merging(added) { current, _ in current })
        return .fullReplace
    }

    // What to lay over the held values for a reader outside the app, `external` being the bridge's masking of these
    // columns. A column the grid masked another way takes the stricter style, over what the grid already hid.
    func externalOverlay(_ external: ColumnMasks) -> ColumnMasks {
        var styles: [Int: MaskingStyle] = [:]
        for (column, style) in external.styles where column < columns.count {
            let shown = masks.styles[column]
            guard shown != style else { continue }
            styles[column] = MaskingStyle.strictest(shown, style)
        }
        return ColumnMasks(styles: styles)
    }

    func externallyMasked(by external: ColumnMasks) -> TableRows {
        let overlay = externalOverlay(external)
        guard !overlay.isEmpty else { return self }
        var copy = self
        for index in copy.rows.indices {
            for column in overlay.styles.keys where column < copy.rows[index].values.count {
                copy.rows[index].values[column] = overlay.value(copy.rows[index].values[column], column: column)
            }
        }
        copy.masks = ColumnMasks(styles: masks.styles.merging(overlay.styles) { _, stricter in stricter })
        return copy
    }

    // A cell an edit or an earlier load already filled keeps what it holds.
    @discardableResult
    mutating func fillUnloaded(_ values: [RowID: [Int: PluginCellValue]]) -> Delta {
        var changed: Set<CellPosition> = []
        for (id, columns) in values {
            guard let row = indexByID[id] else { continue }
            for (column, value) in columns where rows[row].unloadedColumns[column] != nil {
                guard column < rows[row].values.count else { continue }
                rows[row].values[column] = masks.value(value, column: column)
                rows[row].unloadedColumns.removeValue(forKey: column)
                changed.insert(CellPosition(row: row, column: column))
            }
        }
        return changed.isEmpty ? .none : .cellsChanged(changed)
    }

    func index(of id: RowID) -> Int? {
        indexByID[id]
    }

    func row(withID id: RowID) -> Row? {
        guard let index = indexByID[id] else { return nil }
        return rows[index]
    }

    func rowLocator(for id: RowID) -> String? {
        rowLocators[id]
    }

    /// Writes a value into a cell, or with `isAbsent` takes the field out of the row. A value
    /// written into a missing field puts the field back.
    @discardableResult
    mutating func edit(row: Int, column: Int, value: PluginCellValue, isAbsent: Bool = false) -> Delta {
        guard row >= 0, row < rows.count else { return .none }
        guard column >= 0, column < columns.count else { return .none }
        guard column < rows[row].values.count else { return .none }
        guard write(isAbsent ? .null : value, isAbsent: isAbsent, row: row, column: column) else { return .none }
        return .cellChanged(row: row, column: column)
    }

    /// Writes each value, and takes the field out of the row for every position in `absentCells`.
    @discardableResult
    mutating func editMany(
        _ edits: [(row: Int, column: Int, value: PluginCellValue)],
        absentCells: Set<CellPosition> = []
    ) -> Delta {
        var changed: Set<CellPosition> = []
        for edit in edits {
            guard edit.row >= 0, edit.row < rows.count else { continue }
            guard edit.column >= 0, edit.column < columns.count else { continue }
            guard edit.column < rows[edit.row].values.count else { continue }
            let position = CellPosition(row: edit.row, column: edit.column)
            let isAbsent = absentCells.contains(position)
            guard write(isAbsent ? .null : edit.value, isAbsent: isAbsent, row: edit.row, column: edit.column) else {
                continue
            }
            changed.insert(position)
        }
        if changed.isEmpty { return .none }
        return .cellsChanged(changed)
    }

    private mutating func write(_ value: PluginCellValue, isAbsent: Bool, row: Int, column: Int) -> Bool {
        guard !masks.isMasked(column) else { return false }
        let wasAbsent = rows[row].isAbsent(column)
        let wasUnloaded = rows[row].unloadedColumns.removeValue(forKey: column) != nil
        guard rows[row].values[column] != value || wasAbsent != isAbsent || wasUnloaded else { return false }
        rows[row].values[column] = value
        if isAbsent {
            rows[row].absentColumns.insert(column)
        } else if wasAbsent {
            rows[row].absentColumns.remove(column)
        }
        return true
    }

    @discardableResult
    mutating func appendInsertedRow(
        id: RowID = .inserted(UUID()),
        values: [PluginCellValue],
        absentColumns: Set<Int> = []
    ) -> Delta {
        guard indexByID[id] == nil else { return .none }
        let normalized = Self.normalize(values: values, toCount: columns.count)
        let row = Row(id: id, values: normalized, absentColumns: Self.clamp(absentColumns, toCount: columns.count))
        let newIndex = rows.count
        rows.append(row)
        indexByID[row.id] = newIndex
        return .rowsInserted(IndexSet(integer: newIndex))
    }

    @discardableResult
    mutating func insertInsertedRow(
        at index: Int,
        id: RowID = .inserted(UUID()),
        values: [PluginCellValue],
        absentColumns: Set<Int> = []
    ) -> Delta {
        guard index >= 0, index <= rows.count, indexByID[id] == nil else { return .none }
        let normalized = Self.normalize(values: values, toCount: columns.count)
        let row = Row(id: id, values: normalized, absentColumns: Self.clamp(absentColumns, toCount: columns.count))
        rows.insert(row, at: index)
        for offset in index..<rows.count {
            indexByID[rows[offset].id] = offset
        }
        return .rowsInserted(IndexSet(integer: index))
    }

    @discardableResult
    mutating func appendPage(
        _ pageRows: [[PluginCellValue]],
        startingAt offset: Int,
        rowLocators pageLocators: [String?]? = nil,
        exportDocuments: [PluginExportDocument]? = nil,
        absentCells: [Int: Set<Int>] = [:],
        unloadedCells: [Int: [Int: Int]] = [:]
    ) -> Delta {
        guard !pageRows.isEmpty else { return .none }
        let firstIndex = rows.count
        rows.reserveCapacity(rows.count + pageRows.count)
        indexByID.reserveCapacity(indexByID.count + pageRows.count)
        for (idx, values) in pageRows.enumerated() {
            let normalized = Self.normalize(values: masks.row(values), toCount: columns.count)
            let row = Row(
                id: .existing(offset + idx),
                values: normalized,
                absentColumns: Self.clamp(absentCells[idx] ?? [], toCount: columns.count),
                unloadedColumns: Self.clamp(unloadedCells[idx] ?? [:], toCount: columns.count),
                exportSnapshot: Self.exportSnapshot(
                    documents: exportDocuments, index: idx, count: pageRows.count,
                    columns: columns, values: normalized, rawValues: values, absent: absentCells[idx] ?? [], masks: masks,
                    policy: exportPolicy, table: exportTable
                )
            )
            let newIndex = firstIndex + idx
            rows.append(row)
            indexByID[row.id] = newIndex
        }
        rowLocators.merge(Self.locators(pageLocators, rowCount: pageRows.count, offset: offset)) { $1 }
        return .rowsInserted(IndexSet(integersIn: firstIndex...(rows.count - 1)))
    }

    @discardableResult
    mutating func remove(rowIDs: Set<RowID>) -> Delta {
        guard !rowIDs.isEmpty else { return .none }
        var indices = IndexSet()
        for id in rowIDs {
            if let i = indexByID[id] {
                indices.insert(i)
            }
        }
        return removeIndices(indices)
    }

    @discardableResult
    mutating func remove(at indices: IndexSet) -> Delta {
        let valid = indices.filteredIndexSet { $0 >= 0 && $0 < rows.count }
        return removeIndices(valid)
    }

    /// Puts the rows in a new order and rebuilds the id index with them.
    ///
    /// The ids are the ones the rows already carry, so a reorder keeps every row's identity and
    /// only `indexByID` has to move. Assigning `rows` on its own leaves that index pointing at the
    /// old positions, which is what every lookup by `RowID` reads.
    mutating func reorderRows(_ reordered: ContiguousArray<Row>) {
        rows = reordered
        indexByID = Self.buildIndex(for: reordered)
    }

    @discardableResult
    mutating func replace(
        rows replacementRows: [[PluginCellValue]],
        offset: Int = 0,
        rowLocators replacementLocators: [String?]? = nil,
        exportDocuments: [PluginExportDocument]? = nil,
        absentCells: [Int: Set<Int>] = [:],
        unloadedCells: [Int: [Int: Int]] = [:]
    ) -> Delta {
        adopt(Self.prepare(
            replacementRows,
            offset: offset,
            rowLocators: replacementLocators,
            exportDocuments: exportDocuments,
            absentCells: absentCells,
            unloadedCells: unloadedCells,
            shape: rowShape
        ))
        return .fullReplace
    }

    @discardableResult
    mutating func updateDisplayMetadata(
        columnTypes: [ColumnType]? = nil,
        columnDefaults: [String: String?]? = nil,
        columnForeignKeys: [String: ForeignKeyInfo]? = nil,
        columnEnumValues: [String: [String]]? = nil,
        columnNullable: [String: Bool]? = nil,
        columnComments: [String: String]? = nil,
        columnIdentity: [String: IdentityKind]? = nil,
        columnDeclaredTypes: [String: String]? = nil,
        generatedColumns: Set<String>? = nil,
        rowMatchPolicy: RowMatchPolicy? = nil,
        hasAuthoritativeSchema: Bool? = nil
    ) -> Delta {
        var didChange = false
        if let columnTypes, columnTypes != self.columnTypes {
            self.columnTypes = columnTypes
            didChange = true
        }
        if let columnDefaults, columnDefaults != self.columnDefaults {
            self.columnDefaults = columnDefaults
            didChange = true
        }
        if let columnForeignKeys {
            if columnForeignKeys != self.columnForeignKeys {
                self.columnForeignKeys = columnForeignKeys
                didChange = true
            }
            foreignKeysFetched = true
        }
        if let columnEnumValues, columnEnumValues != self.columnEnumValues {
            self.columnEnumValues = columnEnumValues
            didChange = true
        }
        if let columnNullable, columnNullable != self.columnNullable {
            self.columnNullable = columnNullable
            didChange = true
        }
        if let columnComments, columnComments != self.columnComments {
            self.columnComments = columnComments
            didChange = true
        }
        if let columnIdentity, columnIdentity != self.columnIdentity {
            self.columnIdentity = columnIdentity
            didChange = true
        }
        if let columnDeclaredTypes, columnDeclaredTypes != self.columnDeclaredTypes {
            self.columnDeclaredTypes = columnDeclaredTypes
            didChange = true
        }
        if let generatedColumns, generatedColumns != self.generatedColumns {
            self.generatedColumns = generatedColumns
            didChange = true
        }
        if let rowMatchPolicy, rowMatchPolicy != self.rowMatchPolicy {
            self.rowMatchPolicy = rowMatchPolicy
            didChange = true
        }
        if let hasAuthoritativeSchema, hasAuthoritativeSchema != self.hasAuthoritativeSchema {
            self.hasAuthoritativeSchema = hasAuthoritativeSchema
            didChange = true
        }
        return didChange ? .columnsReplaced : .none
    }

    static func from(
        queryRows: [[PluginCellValue]],
        columns: [String],
        columnTypes: [ColumnType],
        columnDefaults: [String: String?] = [:],
        columnForeignKeys: [String: ForeignKeyInfo] = [:],
        columnEnumValues: [String: [String]] = [:],
        columnNullable: [String: Bool] = [:],
        columnComments: [String: String] = [:],
        columnIdentity: [String: IdentityKind] = [:],
        columnDeclaredTypes: [String: String] = [:],
        generatedColumns: Set<String> = [],
        rowMatchPolicy: RowMatchPolicy = .none,
        hasAuthoritativeSchema: Bool = false,
        foreignKeysFetched: Bool = false,
        rowLocators: [String?]? = nil,
        exportDocuments: [PluginExportDocument]? = nil,
        absentCells: [Int: Set<Int>] = [:],
        unloadedCells: [Int: [Int: Int]] = [:],
        masks: ColumnMasks = .none,
        exportPolicy: MaskingPolicy = .none,
        exportTable: String? = nil,
        columnOrigins: [PluginColumnOrigin?]? = nil
    ) -> TableRows {
        from(
            prepared: prepare(
                queryRows,
                rowLocators: rowLocators,
                exportDocuments: exportDocuments,
                absentCells: absentCells,
                unloadedCells: unloadedCells,
                shape: RowShape(columns: columns, masks: masks, exportPolicy: exportPolicy, exportTable: exportTable)
            ),
            columnTypes: columnTypes,
            columnDefaults: columnDefaults,
            columnForeignKeys: columnForeignKeys,
            columnEnumValues: columnEnumValues,
            columnNullable: columnNullable,
            columnComments: columnComments,
            columnIdentity: columnIdentity,
            columnDeclaredTypes: columnDeclaredTypes,
            generatedColumns: generatedColumns,
            rowMatchPolicy: rowMatchPolicy,
            hasAuthoritativeSchema: hasAuthoritativeSchema,
            foreignKeysFetched: foreignKeysFetched,
            columnOrigins: columnOrigins
        )
    }

    static func from(
        prepared: PreparedRows,
        columnTypes: [ColumnType],
        columnDefaults: [String: String?] = [:],
        columnForeignKeys: [String: ForeignKeyInfo] = [:],
        columnEnumValues: [String: [String]] = [:],
        columnNullable: [String: Bool] = [:],
        columnComments: [String: String] = [:],
        columnIdentity: [String: IdentityKind] = [:],
        columnDeclaredTypes: [String: String] = [:],
        generatedColumns: Set<String> = [],
        rowMatchPolicy: RowMatchPolicy = .none,
        hasAuthoritativeSchema: Bool = false,
        foreignKeysFetched: Bool = false,
        columnOrigins: [PluginColumnOrigin?]? = nil
    ) -> TableRows {
        let shape = prepared.shape
        var tableRows = TableRows(
            columns: shape.columns,
            columnTypes: columnTypes,
            columnDefaults: columnDefaults,
            columnForeignKeys: columnForeignKeys,
            columnEnumValues: columnEnumValues,
            columnNullable: columnNullable,
            columnComments: columnComments,
            columnIdentity: columnIdentity,
            columnDeclaredTypes: columnDeclaredTypes,
            generatedColumns: generatedColumns,
            rowMatchPolicy: rowMatchPolicy,
            hasAuthoritativeSchema: hasAuthoritativeSchema,
            foreignKeysFetched: foreignKeysFetched
        )
        tableRows.adopt(prepared)
        tableRows.masks = shape.masks
        tableRows.exportPolicy = shape.exportPolicy
        tableRows.exportTable = shape.exportTable
        tableRows.reportedOrigins = columnOrigins.map { (columns: shape.columns, origins: $0) }
        return tableRows
    }

    var rowShape: RowShape {
        RowShape(columns: columns, masks: masks, exportPolicy: exportPolicy, exportTable: exportTable)
    }

    // Nil when the rows were built for other columns or masks, as after a masking rule saved while they were built.
    mutating func install(_ prepared: PreparedRows) -> Delta? {
        guard prepared.fits(rowShape) else { return nil }
        adopt(prepared)
        return .fullReplace
    }

    private mutating func adopt(_ prepared: PreparedRows) {
        rows = prepared.rows
        indexByID = prepared.indexByID
        rowLocators = prepared.rowLocators
    }

    static let cancellationCheckInterval = 4_096

    // A Fetch All or a first page past the row cap is millions of rows, too many to build on the main actor.
    // A Stop ends the build within one interval of rows; the result is then incomplete and never installs.
    @concurrent
    static func preparing<Source: RandomAccessCollection & Sendable>(
        _ queryRows: Source,
        offset: Int = 0,
        rowLocators: [String?]? = nil,
        exportDocuments: [PluginExportDocument]? = nil,
        absentCells: [Int: Set<Int>] = [:],
        unloadedCells: [Int: [Int: Int]] = [:],
        shape: RowShape
    ) async -> PreparedRows where Source.Element == [PluginCellValue] {
        build(
            queryRows,
            offset: offset,
            rowLocators: rowLocators,
            exportDocuments: exportDocuments,
            absentCells: absentCells,
            unloadedCells: unloadedCells,
            shape: shape,
            stopsOnCancel: true
        )
    }

    // Never stops early: it is also the fallback that has to land every row, inside a task a Stop may have cancelled.
    static func prepare<Source: RandomAccessCollection>(
        _ queryRows: Source,
        offset: Int = 0,
        rowLocators: [String?]? = nil,
        exportDocuments: [PluginExportDocument]? = nil,
        absentCells: [Int: Set<Int>] = [:],
        unloadedCells: [Int: [Int: Int]] = [:],
        shape: RowShape
    ) -> PreparedRows where Source.Element == [PluginCellValue] {
        build(
            queryRows,
            offset: offset,
            rowLocators: rowLocators,
            exportDocuments: exportDocuments,
            absentCells: absentCells,
            unloadedCells: unloadedCells,
            shape: shape,
            stopsOnCancel: false
        )
    }

    private static func build<Source: RandomAccessCollection>(
        _ queryRows: Source,
        offset: Int,
        rowLocators: [String?]?,
        exportDocuments: [PluginExportDocument]?,
        absentCells: [Int: Set<Int>],
        unloadedCells: [Int: [Int: Int]],
        shape: RowShape,
        stopsOnCancel: Bool
    ) -> PreparedRows where Source.Element == [PluginCellValue] {
        let count = queryRows.count
        let columnCount = shape.columns.count
        var rows = ContiguousArray<Row>()
        rows.reserveCapacity(count)
        var index = [RowID: Int]()
        index.reserveCapacity(count)
        for (position, rowIndex) in zip(0..., queryRows.indices) {
            if stopsOnCancel, position.isMultiple(of: cancellationCheckInterval), Task.isCancelled {
                return PreparedRows(shape: shape, rows: [], indexByID: [:], rowLocators: [:], isComplete: false)
            }
            let values = queryRows[rowIndex]
            let normalized = normalize(values: shape.masks.row(values), toCount: columnCount)
            let absent = absentCells[position] ?? []
            let row = Row(
                id: .existing(offset + position),
                values: normalized,
                absentColumns: clamp(absent, toCount: columnCount),
                unloadedColumns: clamp(unloadedCells[position] ?? [:], toCount: columnCount),
                exportSnapshot: exportSnapshot(
                    documents: exportDocuments, index: position, count: count,
                    columns: shape.columns, values: normalized, rawValues: values, absent: absent, masks: shape.masks,
                    policy: shape.exportPolicy, table: shape.exportTable
                )
            )
            rows.append(row)
            index[row.id] = position
        }
        return PreparedRows(
            shape: shape,
            rows: rows,
            indexByID: index,
            rowLocators: locators(rowLocators, rowCount: count, offset: offset),
            isComplete: true
        )
    }

    private static func exportSnapshot(
        documents: [PluginExportDocument]?, index: Int, count: Int,
        columns: [String], values: ContiguousArray<PluginCellValue>, rawValues: [PluginCellValue],
        absent: Set<Int>, masks: ColumnMasks,
        policy: MaskingPolicy, table: String?
    ) -> DocumentExportSnapshot? {
        guard let documents, documents.count == count else { return nil }
        return DocumentExportSnapshot(
            document: ExportDocumentMasking.document(
                documents[index], columns: columns, masks: masks, policy: policy, table: table, row: rawValues
            ),
            values: values,
            absentColumns: clamp(absent, toCount: columns.count),
            maskedFields: maskedFields(in: documents[index], columns: columns, masks: masks, policy: policy, table: table)
        )
    }

    private static func maskedFields(
        in document: PluginExportDocument, columns: [String], masks: ColumnMasks, policy: MaskingPolicy, table: String?
    ) -> Set<String> {
        Set(document.fields.compactMap { field in
            let columnStyle = columns.firstIndex(of: field.name).flatMap { masks.styles[$0] }
            let style = columnStyle ?? policy.style(table: table, column: field.name, typeName: field.typeName)
            return style == nil ? nil : field.name
        })
    }

    /// Locators that do not pair one to one with the rows are dropped rather than guessed at.
    private static func locators(_ locators: [String?]?, rowCount: Int, offset: Int) -> [RowID: String] {
        guard let locators, locators.count == rowCount else { return [:] }
        var keyed: [RowID: String] = [:]
        for (index, locator) in locators.enumerated() {
            guard let locator else { continue }
            keyed[.existing(offset + index)] = locator
        }
        return keyed
    }

    private mutating func removeIndices(_ indices: IndexSet) -> Delta {
        guard !indices.isEmpty else { return .none }
        for index in indices.reversed() {
            let removedID = rows[index].id
            rows.remove(at: index)
            indexByID.removeValue(forKey: removedID)
            rowLocators.removeValue(forKey: removedID)
        }
        if let minRemoved = indices.min(), minRemoved < rows.count {
            for offset in minRemoved..<rows.count {
                indexByID[rows[offset].id] = offset
            }
        }
        return .rowsRemoved(indices)
    }

    private static func normalize(values: [PluginCellValue], toCount targetCount: Int) -> ContiguousArray<PluginCellValue> {
        if values.count == targetCount {
            return ContiguousArray(values)
        }
        var result = ContiguousArray<PluginCellValue>()
        result.reserveCapacity(targetCount)
        if values.count > targetCount {
            result.append(contentsOf: values.prefix(targetCount))
        } else {
            result.append(contentsOf: values)
            result.append(contentsOf: ContiguousArray(repeating: .null, count: targetCount - values.count))
        }
        return result
    }

    private static func clamp(_ absentColumns: Set<Int>, toCount targetCount: Int) -> Set<Int> {
        guard absentColumns.contains(where: { $0 < 0 || $0 >= targetCount }) else { return absentColumns }
        return absentColumns.filter { $0 >= 0 && $0 < targetCount }
    }

    private static func clamp(_ unloadedColumns: [Int: Int], toCount targetCount: Int) -> [Int: Int] {
        guard unloadedColumns.keys.contains(where: { $0 < 0 || $0 >= targetCount }) else { return unloadedColumns }
        return unloadedColumns.filter { $0.key >= 0 && $0.key < targetCount }
    }

    private static func buildIndex(for rows: ContiguousArray<Row>) -> [RowID: Int] {
        var index = [RowID: Int]()
        index.reserveCapacity(rows.count)
        for (i, row) in rows.enumerated() {
            index[row.id] = i
        }
        return index
    }
}

extension TableRows {
    // A SET cell holds several of its values at once, so only an ENUM is filtered by picking one.
    var filterPickerValues: [String: [String]] {
        let setColumns = Set(zip(columns, columnTypes).compactMap { name, type in type.isSetType ? name : nil })
        return columnEnumValues.filter { !setColumns.contains($0.key) }
    }
}

extension TableRows {
    // What building a row reads from the rows it joins: the masks, and the column names export documents match.
    struct RowShape: Equatable, Sendable {
        let columns: [String]
        let masks: ColumnMasks
        let exportPolicy: MaskingPolicy
        let exportTable: String?
    }

    // Rows built from one result with their index, which install by assignment while the shape still holds.
    struct PreparedRows: Sendable {
        let shape: RowShape
        let rows: ContiguousArray<Row>
        fileprivate let indexByID: [RowID: Int]
        fileprivate let rowLocators: [RowID: String]
        // False when a Stop ended the build early: the rows are not the result.
        let isComplete: Bool

        func fits(_ target: RowShape) -> Bool {
            isComplete && shape == target
        }
    }
}
