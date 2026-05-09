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
    let safeModeLevel: SafeModeLevel

    private(set) var rows: [Row]
    var currentIndex: Int
    var isEditing = false
    private(set) var editedValues: [String?] = []
    private(set) var loadingCell: Int?
    private(set) var fullValueOverrides: [Int: [Int: String?]] = [:]
    private(set) var isSaving = false
    var operationError: AppError?
    private(set) var showSaveSuccess = false

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
        safeModeLevel: SafeModeLevel = .off,
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
        self.safeModeLevel = safeModeLevel
        self.foreignKeys = foreignKeys
        self.onSaved = onSaved
        self.loadFullValueProvider = loadFullValue
    }

    deinit {
        dismissSuccessTask?.cancel()
    }

    // MARK: - Computed

    var isView: Bool {
        guard let table else { return false }
        return table.type == .view || table.type == .materializedView
    }

    var canEdit: Bool {
        table != nil && session != nil && !columnDetails.isEmpty && !isView
            && !safeModeLevel.blocksWrites
            && columnDetails.contains(where: { $0.isPrimaryKey })
    }

    var supportsLazyLoading: Bool { loadFullValueProvider != nil }

    var currentRowCells: [Cell] {
        guard currentIndex >= 0, currentIndex < rows.count else { return [] }
        return rows[currentIndex].cells
    }

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

    // MARK: - Save

    func saveChanges() async -> Bool {
        guard let session, let table else { return false }

        isSaving = true
        defer { isSaving = false }

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

        var changes: [(column: String, value: String?)] = []
        for (index, column) in columns.enumerated() {
            if isPrimaryKey(at: index) { continue }
            guard index < editedValues.count else { continue }
            let oldValue = index < currentRow.count ? currentRow[index] : nil
            let newValue = editedValues[index]
            if oldValue != newValue {
                changes.append((column: column.name, value: newValue))
            }
        }

        guard !changes.isEmpty else {
            isEditing = false
            editedValues = []
            return true
        }

        let sql = SQLBuilder.buildUpdate(
            table: table.name,
            type: databaseType,
            changes: changes,
            primaryKeys: pkValues
        )

        do {
            _ = try await session.driver.execute(query: sql)
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
