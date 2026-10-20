import Foundation
import os
import TableProDatabase
import TableProModels
import TableProTabularIO

@MainActor
@Observable
final class RowDetailViewModel {
    private static let logger = Logger(subsystem: "com.TablePro", category: "RowDetailViewModel")

    let columns: [ColumnInfo]
    let columnDetails: [ColumnInfo]
    let foreignKeys: [ForeignKeyInfo]
    let table: TableInfo?
    let session: ConnectionSession?
    let databaseType: DatabaseType
    let schema: String?
    @ObservationIgnored private let readSafeModeLevel: () -> SafeModeLevel

    private(set) var rows: [Row]
    var currentIndex: Int
    var isEditing = false
    private(set) var editedValues: [String?] = []
    private(set) var loadingCell: Int?
    private(set) var fullValueOverrides: [Int: [Int: String?]] = [:]
    private(set) var isSaving = false
    private(set) var pendingWriteConfirmation = false
    var operationError: AppError?
    private(set) var showSaveSuccess = false

    @ObservationIgnored private var writeGate = ConfirmedWriteGate<RowWriteBatch>()

    @ObservationIgnored let onSaved: (() -> Void)?
    @ObservationIgnored let loadFullValueProvider: ((CellRef) async throws -> String?)?
    @ObservationIgnored private var dismissSuccessTask: Task<Void, Never>?

    init(
        columns: [ColumnInfo],
        rows: [Row],
        initialIndex: Int,
        table: TableInfo? = nil,
        session: ConnectionSession? = nil,
        columnDetails: [ColumnInfo] = [],
        databaseType: DatabaseType = .sqlite,
        schema: String? = nil,
        safeModeLevel: @escaping () -> SafeModeLevel = { .off },
        foreignKeys: [ForeignKeyInfo] = [],
        onSaved: (() -> Void)? = nil,
        loadFullValue: ((CellRef) async throws -> String?)? = nil
    ) {
        self.columns = columns
        self.rows = rows
        self.currentIndex = initialIndex
        self.table = table
        self.session = session
        self.columnDetails = columnDetails
        self.databaseType = databaseType
        self.schema = schema
        self.readSafeModeLevel = safeModeLevel
        self.foreignKeys = foreignKeys
        self.onSaved = onSaved
        self.loadFullValueProvider = loadFullValue
    }

    deinit {
        dismissSuccessTask?.cancel()
    }

    // MARK: - Computed

    var safeModeLevel: SafeModeLevel { readSafeModeLevel() }

    /// Asked of the kind rather than compared against the two view cases, so a MariaDB sequence,
    /// which refuses UPDATE and DELETE with ERROR 1031, is read-only here as it is on Mac.
    var allowsRowEditing: Bool {
        table?.type.allowsRowEditing ?? false
    }

    var canEdit: Bool {
        table != nil && session != nil && !columnDetails.isEmpty && allowsRowEditing
            && !safeModeLevel.blocksWrites
            && currentLocator != nil
    }

    private var rowIdentity: RowIdentity { RowLocator.identity(of: session?.driver) }

    private var currentLocator: RowLocator? {
        RowLocator.locate(
            cells: cells(at: currentIndex), columns: columns, columnDetails: columnDetails, identity: rowIdentity
        )
    }

    private func primaryKeyValues(at rowIndex: Int) -> [(column: String, value: String)]? {
        Self.primaryKeyValues(cells: cells(at: rowIndex), columns: columns, columnDetails: columnDetails)
    }

    static func primaryKeyValues(
        cells: [Cell], columns: [ColumnInfo], columnDetails: [ColumnInfo]
    ) -> [(column: String, value: String)]? {
        RowLocator.locate(cells: cells, columns: columns, columnDetails: columnDetails, identity: .keyColumns)?.keyValues
    }

    var supportsLazyLoading: Bool { loadFullValueProvider != nil }

    var currentRow: [String?] {
        row(at: currentIndex)
    }

    func row(at index: Int) -> [String?] {
        guard index >= 0, index < rows.count else { return [] }
        let overrides = fullValueOverrides[index] ?? [:]
        return rows[index].legacyValues.enumerated().map { idx, base in
            overrides[idx] ?? base
        }
    }

    func cells(at index: Int) -> [Cell] {
        guard index >= 0, index < rows.count else { return [] }
        return rows[index].cells
    }

    // A binary value stays a placeholder even when loaded: what the driver reads back is not its bytes.
    func completeCells(at rowIndex: Int) -> [Cell] {
        let overrides = fullValueOverrides[rowIndex] ?? [:]
        return cells(at: rowIndex).enumerated().map { index, cell in
            guard case .truncatedText = cell, let loaded = overrides[index] else { return cell }
            return loaded.map(Cell.text) ?? .null
        }
    }

    func completeValue(forRow rowIndex: Int, at index: Int) -> String? {
        let rowCells = cells(at: rowIndex)
        guard index >= 0, index < rowCells.count else { return nil }
        switch rowCells[index] {
        case .text(let value):
            return value
        case .truncatedText:
            return fullValueOverrides[rowIndex]?[index] ?? nil
        case .null, .binary:
            return nil
        }
    }

    // MariaDB's catalog names a JSON column longtext while its result column says JSON, so either type decides.
    func isJSON(at index: Int) -> Bool {
        guard index >= 0, index < columns.count else { return false }
        let column = columns[index]
        if ColumnInfo.isJSONType(typeName: column.typeName) { return true }
        return columnDetail(for: column.name).map { ColumnInfo.isJSONType(typeName: $0.typeName) } ?? false
    }

    func jsonText(forRow rowIndex: Int, at index: Int) -> String? {
        guard index < columns.count, let value = completeValue(forRow: rowIndex, at: index) else { return nil }
        if isJSON(at: index) { return value }
        let typeName = (columnDetail(for: columns[index].name) ?? columns[index]).typeName
        guard ColumnInfo.mayHoldJSONText(typeName: typeName), Self.opensContainer(value) else { return nil }
        switch JSONValidation.check(value) {
        case .success(.object), .success(.array):
            return value
        default:
            return nil
        }
    }

    private static func opensContainer(_ value: String) -> Bool {
        let first = value.utf8.first { $0 != 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D }
        return first == UInt8(ascii: "{") || first == UInt8(ascii: "[")
    }

    func columnDetail(for name: String) -> ColumnInfo? {
        columnDetails.first { $0.name == name }
    }

    func isPrimaryKey(at index: Int) -> Bool {
        guard index >= 0, index < columns.count else { return false }
        let column = columns[index]
        return columnDetail(for: column.name)?.isPrimaryKey ?? column.isPrimaryKey
    }

    func isNullable(at index: Int) -> Bool {
        guard index >= 0, index < columns.count else { return true }
        let column = columns[index]
        return columnDetail(for: column.name)?.isNullable ?? column.isNullable
    }

    /// A key identifies the row and stays as it is, and a column the server owns cannot be given a value, however
    /// the cell is drawn.
    func takesEdits(at index: Int) -> Bool {
        guard !isPrimaryKey(at: index), !isServerOwned(at: index) else { return false }
        return isEditableAsText(at: index)
    }

    func isServerOwned(at index: Int) -> Bool {
        guard index >= 0, index < columns.count else { return false }
        return columnDetail(for: columns[index].name)?.isServerOwned ?? false
    }

    func isEditableAsText(at index: Int) -> Bool {
        let rowCells = cells(at: currentIndex)
        guard index >= 0, index < rowCells.count else { return false }
        switch rowCells[index] {
        case .null, .text:
            return true
        case .truncatedText:
            return hasOverride(forRow: currentIndex, cellIndex: index)
        case .binary:
            return false
        }
    }

    // MARK: - Row Navigation

    var showsRowNavigator: Bool { !isEditing }
    var canGoToPreviousRow: Bool { !isEditing && currentIndex > 0 }
    var canGoToNextRow: Bool { !isEditing && currentIndex < rows.count - 1 }

    func goToPreviousRow() {
        guard canGoToPreviousRow else { return }
        currentIndex -= 1
    }

    func goToNextRow() {
        guard canGoToNextRow else { return }
        currentIndex += 1
    }

    // MARK: - Edit Lifecycle

    func startEditing() {
        editedValues = currentRow
        isEditing = true
        showSaveSuccess = false
    }

    func cancelEditing() {
        isEditing = false
        editedValues = []
        showSaveSuccess = false
    }

    func setEditedValue(_ value: String, at index: Int) {
        guard index < editedValues.count, isEditableAsText(at: index) else { return }
        editedValues[index] = value
    }

    func toggleNull(at index: Int) {
        guard index < editedValues.count, isEditableAsText(at: index) else { return }
        if editedValues[index] == nil {
            editedValues[index] = ""
        } else {
            editedValues[index] = nil
        }
    }

    var hasUnsavedEdits: Bool {
        isEditing && !editedColumnIndices.isEmpty
    }

    private var editedColumnIndices: [Int] {
        let original = currentRow
        return columns.indices.filter { index in
            guard index < editedValues.count, takesEdits(at: index) else {
                return false
            }
            let oldValue = index < original.count ? original[index] : nil
            return oldValue != writtenValue(at: index, stored: oldValue)
        }
    }

    private var editedChanges: [(column: String, value: String?)] {
        let original = currentRow
        return editedColumnIndices.map { index in
            (column: columns[index].name, value: writtenValue(at: index, stored: index < original.count ? original[index] : nil))
        }
    }

    /// What Save writes for a field. An emptied date, number or boolean is NULL, since `''` is no
    /// value of those types and MySQL without strict mode stores it as the zero date. In a NOT NULL
    /// column, which holds neither, the field keeps the stored value and Save writes nothing for it.
    /// A field left as it was is never read again: SQLite can hold `''` in a DATETIME column.
    func writtenValue(at index: Int) -> String? {
        let original = currentRow
        return writtenValue(at: index, stored: index < original.count ? original[index] : nil)
    }

    /// Takes the stored value from the caller's snapshot of the row, which `currentRow` rebuilds on
    /// every read, so a pass over every field stays linear.
    private func writtenValue(at index: Int, stored: String?) -> String? {
        guard index < editedValues.count else { return nil }
        let value = editedValues[index]
        guard value == "", stored != "", !holdsEmptyString(at: index) else { return value }
        return isNullable(at: index) ? nil : stored
    }

    private func holdsEmptyString(at index: Int) -> Bool {
        guard index >= 0, index < columns.count else { return true }
        if isJSON(at: index) { return false }
        return (columnDetail(for: columns[index].name) ?? columns[index]).holdsEmptyString
    }

    var hasInvalidJSONEdit: Bool {
        firstInvalidJSONEdit() != nil
    }

    private func firstInvalidJSONEdit() -> (column: String, failure: JSONValidation.Failure)? {
        let original = currentRow
        for index in editedColumnIndices where isJSON(at: index) {
            let stored = index < original.count ? original[index] : nil
            guard let value = writtenValue(at: index, stored: stored), !value.isEmpty,
                  case .failure(let failure) = JSONValidation.check(value) else { continue }
            return (columns[index].name, failure)
        }
        return nil
    }

    // MARK: - Save

    func saveChanges() async -> Bool {
        guard let session, let table else { return false }

        pendingWriteConfirmation = false
        writeGate.cancel()
        // The key and row checks below wait on the server; Save and Cancel stay disabled until they answer.
        isSaving = true
        defer { isSaving = false }

        guard RowLocator.canLocate(identity: rowIdentity, columns: columns, columnDetails: columnDetails) else {
            operationError = AppError(
                category: .config,
                title: String(localized: "Cannot Save"),
                message: String(localized: "No primary key values found."),
                recovery: String(localized: "This table needs a primary key to identify the row."),
                underlying: nil
            )
            return false
        }

        guard let locator = currentLocator else {
            operationError = AppError(
                category: .config,
                title: String(localized: "Cannot Save"),
                message: rowIdentity == .everyColumn
                    ? String(localized: "This row holds a value too long or binary to match exactly, so it cannot identify the row.")
                    : String(localized: "This row's primary key is not plain text, so it cannot identify the row."),
                recovery: nil,
                underlying: nil
            )
            return false
        }

        let changes = editedChanges

        guard !changes.isEmpty else {
            isEditing = false
            editedValues = []
            return true
        }

        if let invalid = firstInvalidJSONEdit() {
            operationError = AppError(
                category: .query,
                title: String(localized: "Invalid JSON"),
                message: String(format: String(localized: "The value of %@ is not valid JSON."), invalid.column),
                recovery: invalid.failure.message,
                underlying: nil
            )
            return false
        }

        if let keys = locator.keyValues, let shared = await SharedRowKey.error(
            table: table.name, schema: schema, key: keys,
            columns: columnDetails, type: databaseType, driver: session.driver
        ) {
            operationError = shared
            return false
        }
        if let writer = session.driver as? any DriverRowWriting, let identical = await SharedRowKey.identicalRowsError(
            writer: writer, table: table.name, schema: schema, locator: locator,
            columns: columns.map(\.name), type: databaseType, isUpdate: true
        ) {
            operationError = identical
            return false
        }
        guard isEditing else { return false }

        let batch: RowWriteBatch
        do {
            guard let built = try RowWriteBatch.update(
                table: table.name,
                schema: schema,
                type: databaseType,
                driver: session.driver,
                columns: columns.map(\.name),
                columnDetails: columnDetails,
                locator: locator,
                changes: changes
            ) else { return false }
            batch = built
        } catch {
            let context = ErrorContext(operation: "saveChanges", databaseType: databaseType)
            operationError = ErrorClassifier.classify(error, context: context)
            return false
        }

        switch writeGate.submit(batch, under: safeModeLevel) {
        case .blocked:
            return false
        case .awaitConfirmation:
            pendingWriteConfirmation = true
            return false
        case .run(let batch):
            return await execute(batch)
        }
    }

    func executePendingSave() async -> Bool {
        pendingWriteConfirmation = false
        guard let confirmed = writeGate.confirm(under: safeModeLevel) else { return false }
        // A row matched on every value can change while the confirmation is up, and nothing after the write tells.
        if let session, let table, let writer = session.driver as? any DriverRowWriting, let locator = currentLocator {
            isSaving = true
            let stale = await SharedRowKey.identicalRowsError(
                writer: writer, table: table.name, schema: schema, locator: locator,
                columns: columns.map(\.name), type: databaseType, isUpdate: true
            )
            isSaving = false
            if let stale {
                operationError = stale
                return false
            }
        }
        return await execute(confirmed)
    }

    private func execute(_ batch: RowWriteBatch) async -> Bool {
        isSaving = true
        defer { isSaving = false }
        let rowIndex = currentIndex
        let original = currentRow
        let savedIndices = editedColumnIndices
        let typedCells = Dictionary(uniqueKeysWithValues: savedIndices.map { index in
            let stored = index < original.count ? original[index] : nil
            return (index, writtenValue(at: index, stored: stored).map { Cell.text($0) } ?? .null)
        })

        let affected: Int
        do {
            affected = try await batch.run()
        } catch {
            let context = ErrorContext(operation: "saveChanges", databaseType: databaseType)
            operationError = ErrorClassifier.classify(error, context: context)
            return false
        }
        guard rowIndex >= 0, rowIndex < rows.count else { return false }

        let savedCells: [Int: Cell]
        do {
            savedCells = try await storedCells(at: savedIndices, inRow: rowIndex) ?? typedCells
        } catch CellLookupError.rowNotFound where affected > 0 {
            // The UPDATE landed; a trigger or another session has since changed the row's key.
            Self.logger.error("The saved row is no longer under its primary key")
            savedCells = typedCells
        } catch CellLookupError.rowNotFound {
            // A count of 0 proves nothing on SQL Server under SET NOCOUNT ON, so this never claims the UPDATE did not run.
            operationError = AppError(
                category: .query,
                title: String(localized: "Row Not Found"),
                message: CellLookupError.rowNotFound.localizedDescription,
                recovery: String(localized: "Reload the table to see the row as it is now."),
                underlying: CellLookupError.rowNotFound
            )
            return false
        } catch {
            Self.logger.error("Reading the saved row back failed: \(error.localizedDescription, privacy: .private)")
            savedCells = typedCells
        }
        commitSavedCells(savedCells, toRow: rowIndex)
        isEditing = false
        showSaveSuccess = true
        onSaved?()
        scheduleSuccessDismiss()
        return true
    }

    // The server can store other text than was sent: jsonb drops duplicate keys and reorders the rest. MySQL also
    // counts only changed rows, so this read, not the affected count, tells a missing row from an unchanged one.
    private func storedCells(at columnIndices: [Int], inRow rowIndex: Int) async throws -> [Int: Cell]? {
        guard rowIdentity == .keyColumns, let loadFullValueProvider, let table,
              let pkValues = primaryKeyValues(at: rowIndex) else { return nil }
        let keys = pkValues.map { PrimaryKeyComponent(column: $0.column, value: $0.value) }
        var stored: [Int: Cell] = [:]
        for index in columnIndices {
            let ref = CellRef(table: table.name, column: columns[index].name, primaryKey: keys)
            stored[index] = try await loadFullValueProvider(ref).map { Cell.text($0) } ?? .null
        }
        return stored
    }

    func exportCurrentRow(as format: ExportFormat) -> String? {
        do {
            return try ClipboardExporter.exportRow(
                columns: columns, cells: completeCells(at: currentIndex),
                format: format, tableName: table?.name,
                databaseType: databaseType, driver: session?.driver
            )
        } catch {
            operationError = AppError(
                category: .query,
                title: String(localized: "Cannot Export"),
                message: error.localizedDescription,
                recovery: nil,
                underlying: error
            )
            return nil
        }
    }

    private func commitSavedCells(_ savedCells: [Int: Cell], toRow rowIndex: Int) {
        let cells = rows[rowIndex].cells.enumerated().map { index, cell in
            savedCells[index] ?? cell
        }
        rows[rowIndex] = Row(cells: cells)
        let overrides = (fullValueOverrides[rowIndex] ?? [:]).filter { savedCells[$0.key] == nil }
        fullValueOverrides[rowIndex] = overrides.isEmpty ? nil : overrides
    }

    private func scheduleSuccessDismiss() {
        dismissSuccessTask?.cancel()
        dismissSuccessTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.showSaveSuccess = false }
        }
    }

    // MARK: - Lazy Load

    func loadFullValue(ref: CellRef, forRow rowIndex: Int, cellIndex: Int) async {
        guard let loadFullValueProvider else { return }
        loadingCell = cellIndex
        defer { loadingCell = nil }
        do {
            let fullValue = try await loadFullValueProvider(ref)
            var rowOverrides = fullValueOverrides[rowIndex] ?? [:]
            rowOverrides[cellIndex] = fullValue
            fullValueOverrides[rowIndex] = rowOverrides
            guard isEditing, rowIndex == currentIndex, cellIndex < editedValues.count else { return }
            editedValues[cellIndex] = fullValue
        } catch {
            operationError = AppError(
                category: .network,
                title: String(localized: "Load Failed"),
                message: error.localizedDescription,
                recovery: String(localized: "Try again or check your connection."),
                underlying: error
            )
        }
    }

    func hasOverride(forRow rowIndex: Int, cellIndex: Int) -> Bool {
        fullValueOverrides[rowIndex]?[cellIndex] != nil
    }
}
