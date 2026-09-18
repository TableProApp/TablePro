import Foundation
import os
import TableProDatabase
import TableProModels

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

    @ObservationIgnored private var pendingSaveSQL: String?

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
            && columnDetails.contains(where: { $0.isPrimaryKey })
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
        guard index < editedValues.count else { return }
        editedValues[index] = value
    }

    func toggleNull(at index: Int) {
        guard index < editedValues.count else { return }
        if editedValues[index] == nil {
            editedValues[index] = ""
        } else {
            editedValues[index] = nil
        }
    }

    var hasUnsavedEdits: Bool {
        isEditing && !editedChanges.isEmpty
    }

    private var editedChanges: [(column: String, value: String?)] {
        let original = currentRow
        var changes: [(column: String, value: String?)] = []
        for (index, column) in columns.enumerated() {
            guard !isPrimaryKey(at: index), index < editedValues.count else { continue }
            let oldValue = index < original.count ? original[index] : nil
            let newValue = editedValues[index]
            guard oldValue != newValue else { continue }
            changes.append((column: column.name, value: newValue))
        }
        return changes
    }

    // MARK: - Save

    func saveChanges() async -> Bool {
        guard let session, let table else { return false }

        pendingWriteConfirmation = false
        pendingSaveSQL = nil

        let pkValues: [(column: String, value: String)] = columnDetails.compactMap { col in
            guard col.isPrimaryKey else { return nil }
            let colIndex = columns.firstIndex(where: { $0.name == col.name })
            guard let colIndex, colIndex < currentRow.count, let value = currentRow[colIndex] else { return nil }
            return (column: col.name, value: value)
        }

        guard !pkValues.isEmpty else {
            operationError = AppError(
                category: .config,
                title: String(localized: "Cannot Save"),
                message: String(localized: "No primary key values found."),
                recovery: String(localized: "This table needs a primary key to identify the row."),
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

        let sql = SQLBuilder.buildUpdate(
            table: table.name,
            schema: schema,
            type: databaseType,
            driver: session.driver,
            changes: changes,
            primaryKeys: pkValues
        )

        switch safeModeLevel.writePermission {
        case .blocked:
            return false
        case .requiresConfirmation:
            pendingSaveSQL = sql
            pendingWriteConfirmation = true
            return false
        case .proceed:
            return await execute(sql: sql, session: session)
        }
    }

    func executePendingSave() async -> Bool {
        pendingWriteConfirmation = false
        guard let session, let sql = pendingSaveSQL else { return false }
        pendingSaveSQL = nil
        guard !safeModeLevel.blocksWrites else { return false }
        return await execute(sql: sql, session: session)
    }

    private func execute(sql: String, session: ConnectionSession) async -> Bool {
        isSaving = true
        defer { isSaving = false }

        do {
            try await session.driver.executeWrite([sql])
            guard currentIndex >= 0, currentIndex < rows.count else { return false }
            let newCells = editedValues.map { value -> Cell in
                value.map { Cell.text($0) } ?? .null
            }
            rows[currentIndex] = Row(cells: newCells)
            fullValueOverrides[currentIndex] = nil
            isEditing = false
            showSaveSuccess = true
            onSaved?()
            scheduleSuccessDismiss()
            return true
        } catch {
            let context = ErrorContext(operation: "saveChanges", databaseType: databaseType)
            operationError = ErrorClassifier.classify(error, context: context)
            return false
        }
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

    func loadFullValue(ref: CellRef, cellIndex: Int) async {
        guard let loadFullValueProvider else { return }
        loadingCell = cellIndex
        defer { loadingCell = nil }
        do {
            let fullValue = try await loadFullValueProvider(ref)
            var rowOverrides = fullValueOverrides[currentIndex] ?? [:]
            rowOverrides[cellIndex] = fullValue
            fullValueOverrides[currentIndex] = rowOverrides
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
