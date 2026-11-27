//
//  TableRows.swift
//  TablePro
//

import Foundation
import TableProPluginKit

struct TableRows: Sendable {
    var rows: ContiguousArray<Row>
    private var positions: RowPositions
    private var sparse = SparseRowState()
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
        foreignKeysFetched: Bool = false,
        absentColumns: [RowID: Set<Int>] = [:]
    ) {
        self.rows = rows
        self.positions = RowPositions(of: rows)
        for (id, columns) in absentColumns {
            sparse.setAbsentColumns(columns, for: id)
        }
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
        return isAbsent(rows[row].id, column: column)
    }

    func unloadedByteCount(row: Int, column: Int) -> Int? {
        guard row >= 0, row < rows.count else { return nil }
        return unloadedByteCount(rows[row].id, column: column)
    }

    func isAbsent(_ id: RowID, column: Int) -> Bool {
        sparse.absentColumns[id]?.contains(column) == true
    }

    func absentColumns(of id: RowID) -> Set<Int> {
        sparse.absentColumns[id] ?? []
    }

    var absentColumnsByRow: [RowID: Set<Int>] {
        sparse.absentColumns
    }

    func unloadedByteCount(_ id: RowID, column: Int) -> Int? {
        sparse.unloadedColumns[id]?[column]
    }

    func unloadedColumns(of id: RowID) -> [Int: Int] {
        sparse.unloadedColumns[id] ?? [:]
    }

    func unloadedHead(_ id: RowID, column: Int) -> String? {
        sparse.unloadedHeads[id]?[column]
    }

    func unloadedHeads(of id: RowID) -> [Int: String] {
        sparse.unloadedHeads[id] ?? [:]
    }

    func hasUnloadedValues(_ id: RowID) -> Bool {
        sparse.unloadedColumns[id] != nil
    }

    var hasUnloadedValues: Bool {
        !sparse.unloadedColumns.isEmpty
    }

    var rowIDsWithUnloadedValues: Set<RowID> {
        Set(sparse.unloadedColumns.keys)
    }

    // The row with the values it still has to read from the server, or nil when it has none.
    func unloadedRow(withID id: RowID) -> UnloadedRow? {
        guard let columns = sparse.unloadedColumns[id], let row = row(withID: id) else { return nil }
        return UnloadedRow(row: row, columns: columns)
    }

    func exportSnapshot(of id: RowID) -> DocumentExportSnapshot? {
        sparse.exportSnapshots[id]
    }

    // The driver's document while the row still holds the values it came with.
    func exportDocument(of row: Row) -> PluginExportDocument? {
        sparse.exportSnapshots[row.id]?.document(matching: row.values, absentColumns: absentColumns(of: row.id))
    }

    func record(withID id: RowID) -> RowRecord? {
        guard let row = row(withID: id) else { return nil }
        return RowRecord(
            row: row,
            absentColumns: absentColumns(of: id),
            unloadedColumns: unloadedColumns(of: id),
            exportSnapshot: exportSnapshot(of: id)
        )
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
        }
        sparse.dropUnloadedHeads(inColumns: Set(added.keys))
        let columns = columns
        let policy = exportPolicy
        let table = exportTable
        sparse.mapExportSnapshots { original in
            var snapshot = original
            let masked = Self.maskedFields(in: snapshot.document, columns: columns, masks: addedMasks, policy: policy, table: table)
            snapshot.document = ExportDocumentMasking.document(
                snapshot.document, columns: columns, masks: addedMasks, policy: policy,
                table: table, excluding: snapshot.maskedFields, row: Array(snapshot.values)
            )
            snapshot.maskedFields.formUnion(masked)
            snapshot.values = ContiguousArray(addedMasks.row(Array(snapshot.values)))
            return snapshot
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
            guard let row = positions[id], var unloaded = sparse.unloadedColumns[id] else { continue }
            for (column, value) in columns where unloaded[column] != nil {
                guard column < rows[row].values.count else { continue }
                rows[row].values[column] = masks.value(value, column: column)
                unloaded.removeValue(forKey: column)
                changed.insert(CellPosition(row: row, column: column))
            }
            sparse.setUnloadedColumns(unloaded, for: id)
        }
        return changed.isEmpty ? .none : .cellsChanged(changed)
    }

    func index(of id: RowID) -> Int? {
        positions[id]
    }

    func row(withID id: RowID) -> Row? {
        guard let index = positions[id] else { return nil }
        return rows[index]
    }

    var hashedPositionCount: Int { positions.hashedCount }

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
        let id = rows[row].id
        let wasAbsent = sparse.absentColumns[id]?.contains(column) == true
        let wasUnloaded = sparse.removeUnloadedColumn(column, for: id)
        guard rows[row].values[column] != value || wasAbsent != isAbsent || wasUnloaded else { return false }
        rows[row].values[column] = value
        if isAbsent != wasAbsent {
            sparse.setAbsent(isAbsent, column: column, for: id)
        }
        return true
    }

    @discardableResult
    mutating func appendInsertedRow(
        id: RowID = .inserted(UUID()),
        values: [PluginCellValue],
        absentColumns: Set<Int> = []
    ) -> Delta {
        guard positions[id] == nil else { return .none }
        let normalized = Self.normalize(values: values, toCount: columns.count)
        let newIndex = rows.count
        rows.append(Row(id: id, values: normalized))
        positions.append(id, at: newIndex)
        sparse.setAbsentColumns(Self.clamp(absentColumns, toCount: columns.count), for: id)
        return .rowsInserted(IndexSet(integer: newIndex))
    }

    @discardableResult
    mutating func insertInsertedRow(
        at index: Int,
        id: RowID = .inserted(UUID()),
        values: [PluginCellValue],
        absentColumns: Set<Int> = []
    ) -> Delta {
        guard index >= 0, index <= rows.count, positions[id] == nil else { return .none }
        let normalized = Self.normalize(values: values, toCount: columns.count)
        rows.insert(Row(id: id, values: normalized), at: index)
        positions.reindex(from: index, in: rows)
        sparse.setAbsentColumns(Self.clamp(absentColumns, toCount: columns.count), for: id)
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
        for (idx, read) in pageRows.enumerated() {
            let unloaded = Self.clamp(unloadedCells[idx] ?? [:], toCount: columns.count)
            let (values, heads) = Self.liftingHeads(read, unloaded: unloaded, masks: masks)
            let normalized = Self.normalize(values: masks.row(values), toCount: columns.count)
            let id = RowID.existing(offset + idx)
            sparse.setAbsentColumns(Self.clamp(absentCells[idx] ?? [], toCount: columns.count), for: id)
            sparse.setUnloadedColumns(unloaded, for: id)
            sparse.setUnloadedHeads(heads, for: id)
            sparse.setExportSnapshot(
                Self.exportSnapshot(
                    documents: exportDocuments, index: idx, count: pageRows.count,
                    columns: columns, values: normalized, rawValues: values, absent: absentCells[idx] ?? [], masks: masks,
                    policy: exportPolicy, table: exportTable
                ),
                for: id
            )
            let newIndex = firstIndex + idx
            rows.append(Row(id: id, values: normalized))
            positions.append(id, at: newIndex)
        }
        rowLocators.merge(Self.locators(pageLocators, rowCount: pageRows.count, offset: offset)) { $1 }
        return .rowsInserted(IndexSet(integersIn: firstIndex...(rows.count - 1)))
    }

    @discardableResult
    mutating func remove(rowIDs: Set<RowID>) -> Delta {
        guard !rowIDs.isEmpty else { return .none }
        var indices = IndexSet()
        for id in rowIDs {
            if let i = positions[id] {
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
    /// The ids are the ones the rows already carry, so a reorder keeps every row's identity, and the state kept by id
    /// stays with its row. Assigning `rows` on its own leaves the positions pointing at the old order, which is what
    /// every lookup by `RowID` reads.
    mutating func reorderRows(_ reordered: ContiguousArray<Row>) {
        rows = reordered
        positions = RowPositions(of: reordered)
    }

    // For a result whose rows the tab's buffer took over: the columns and their metadata stay readable.
    mutating func releaseRows() {
        rows = []
        positions = RowPositions()
        sparse = SparseRowState()
        rowLocators = [:]
    }

    func sharesRows(with other: TableRows) -> Bool {
        guard !rows.isEmpty else { return false }
        let mine = rows.withUnsafeBufferPointer { $0.baseAddress }
        return mine == other.rows.withUnsafeBufferPointer { $0.baseAddress }
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
        var typesChanged = false
        if let columnTypes, columnTypes != self.columnTypes {
            self.columnTypes = columnTypes
            typesChanged = true
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
        if typesChanged { return .columnsReplaced }
        return didChange ? .columnMetadataChanged : .none
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
        positions = prepared.positions
        sparse = prepared.sparse
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
        var positions = RowPositions()
        var sparse = SparseRowState()
        for (position, rowIndex) in zip(0..., queryRows.indices) {
            if stopsOnCancel, position.isMultiple(of: cancellationCheckInterval), Task.isCancelled {
                return PreparedRows(
                    shape: shape, rows: [], positions: RowPositions(), sparse: SparseRowState(), rowLocators: [:],
                    isComplete: false
                )
            }
            let unloaded = clamp(unloadedCells[position] ?? [:], toCount: columnCount)
            let (values, heads) = liftingHeads(queryRows[rowIndex], unloaded: unloaded, masks: shape.masks)
            let normalized = normalize(values: shape.masks.row(values), toCount: columnCount)
            let absent = absentCells[position] ?? []
            let id = RowID.existing(offset + position)
            sparse.setAbsentColumns(clamp(absent, toCount: columnCount), for: id)
            sparse.setUnloadedColumns(unloaded, for: id)
            sparse.setUnloadedHeads(heads, for: id)
            sparse.setExportSnapshot(
                exportSnapshot(
                    documents: exportDocuments, index: position, count: count,
                    columns: shape.columns, values: normalized, rawValues: values, absent: absent, masks: shape.masks,
                    policy: shape.exportPolicy, table: shape.exportTable
                ),
                for: id
            )
            rows.append(Row(id: id, values: normalized))
            positions.append(id, at: position)
        }
        return PreparedRows(
            shape: shape,
            rows: rows,
            positions: positions,
            sparse: sparse,
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
        // Nothing can mask a field, so each document is kept as read instead of rebuilt field by field.
        guard !masks.isEmpty || !policy.isEmpty else {
            return DocumentExportSnapshot(
                document: documents[index],
                values: values,
                absentColumns: clamp(absent, toCount: columns.count),
                maskedFields: []
            )
        }
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
            sparse.removeRow(removedID)
            rowLocators.removeValue(forKey: removedID)
        }
        if let minRemoved = indices.min() {
            positions.reindex(from: minRemoved, in: rows)
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

    // A cut text arrives with its first characters in the cell. The row holds NULL there, as for any value left on the
    // server, so no reader takes the characters for the value; the grid shows them. A masked column shows only the size,
    // since a mask over the first characters is not the mask of the value.
    static func liftingHeads(
        _ values: [PluginCellValue],
        unloaded: [Int: Int],
        masks: ColumnMasks
    ) -> (values: [PluginCellValue], heads: [Int: String]) {
        guard !unloaded.isEmpty else { return (values, [:]) }
        var values = values
        var heads: [Int: String] = [:]
        for column in unloaded.keys where values.indices.contains(column) {
            if case .text(let head) = values[column], !head.isEmpty, !masks.isMasked(column) {
                heads[column] = head
            }
            values[column] = .null
        }
        return (values, heads)
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
        fileprivate let positions: RowPositions
        fileprivate let sparse: SparseRowState
        fileprivate let rowLocators: [RowID: String]
        // False when a Stop ended the build early: the rows are not the result.
        let isComplete: Bool

        func fits(_ target: RowShape) -> Bool {
            isComplete && shape == target
        }
    }
}

extension TableRows {
    // A row with the state kept beside it, for telling whether it is still the record it was.
    struct RowRecord: Equatable {
        let row: Row
        let absentColumns: Set<Int>
        let unloadedColumns: [Int: Int]
        let exportSnapshot: DocumentExportSnapshot?
    }
}
