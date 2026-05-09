//
//  DataBrowserViewModel.swift
//  TableProMobile
//

import Foundation
import os
import TableProDatabase
import TableProModels
import TableProQuery

@MainActor
@Observable
final class DataBrowserViewModel {
    enum Phase: Sendable {
        case idle
        case loading
        case loaded
        case truncated(reason: TruncationReason)
        case error(AppError)
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "DataBrowserViewModel")

    private(set) var columns: [ColumnInfo] = []
    private(set) var window: RowWindow
    private(set) var legacyRows: [[String?]] = []
    private(set) var totalRows: Int?
    private(set) var phase: Phase = .idle
    private(set) var rowsAffected: Int?
    private(set) var statusMessage: String?
    private(set) var executionTime: TimeInterval = 0

    private(set) var columnDetails: [ColumnInfo] = []
    private(set) var foreignKeys: [ForeignKeyInfo] = []
    private(set) var pagination = PaginationState(pageSize: 100, currentPage: 0)
    var sortState = SortState()
    var filters: [TableFilter] = []
    var filterLogicMode: FilterLogicMode = .and
    private(set) var activeSearchText = ""
    private(set) var loadError: AppError?
    var operationError: AppError?
    private(set) var isLoading = true
    private(set) var isPageLoading = false
    var memoryWarning: String?

    @ObservationIgnored private var session: ConnectionSession?
    @ObservationIgnored private var table: TableInfo?
    @ObservationIgnored private var databaseType: DatabaseType = .mysql
    @ObservationIgnored private var host: String = ""
    @ObservationIgnored private var pendingRows: [Row] = []
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    private static let flushBatchSize = 200
    private static let flushInterval: Duration = .milliseconds(50)

    init(windowCapacity: Int = 1_000) {
        self.window = RowWindow(capacity: windowCapacity)
    }

    // MARK: - Computed

    var hasActiveSearch: Bool { !activeSearchText.isEmpty }
    var hasActiveFilters: Bool { filters.contains { $0.isEnabled && $0.isValid } }
    var activeFilterCount: Int { filters.filter { $0.isEnabled && $0.isValid }.count }
    var hasPrimaryKeys: Bool { columnDetails.contains(where: \.isPrimaryKey) }

    var paginationLabel: String {
        guard !legacyRows.isEmpty else { return "" }
        let start = pagination.currentOffset + 1
        let end = pagination.currentOffset + legacyRows.count
        if let total = pagination.totalRows {
            return "\(start)-\(end) of \(total)"
        }
        return "\(start)-\(end)"
    }

    // MARK: - Attach

    func attach(session: ConnectionSession?, table: TableInfo, databaseType: DatabaseType, host: String) {
        self.session = session
        self.table = table
        self.databaseType = databaseType
        self.host = host
    }

    // MARK: - Load

    func load(isInitial: Bool = false) async {
        guard let session, let table else {
            loadError = AppError(
                category: .config,
                title: String(localized: "Not Connected"),
                message: String(localized: "No active database session."),
                recovery: String(localized: "Go back and reconnect to the database."),
                underlying: nil
            )
            isLoading = false
            return
        }

        if isInitial || legacyRows.isEmpty { isLoading = true }
        loadError = nil

        do {
            if columnDetails.isEmpty || isInitial {
                columnDetails = try await session.driver.fetchColumns(table: table.name, schema: nil)
            }

            let pkColumns = columnDetails.filter(\.isPrimaryKey).map(\.name)
            let lazyContext = pkColumns.isEmpty ? nil : LazyContext(table: table.name, primaryKeyColumns: pkColumns)
            let query = buildSelectQuery(table: table)

            await loadPage(
                driver: session.driver,
                query: query,
                lazyContext: lazyContext,
                pageSize: pagination.pageSize
            )

            if case .error(let err) = phase {
                loadError = err
                isLoading = false
                return
            }

            if legacyRows.count < pagination.pageSize, pagination.totalRows == nil {
                pagination.totalRows = pagination.currentOffset + legacyRows.count
            }

            if foreignKeys.isEmpty || isInitial {
                do {
                    foreignKeys = try await session.driver.fetchForeignKeys(table: table.name, schema: nil)
                } catch {
                    Self.logger.warning("Failed to fetch foreign keys: \(error.localizedDescription, privacy: .public)")
                }
            }

            if pagination.totalRows == nil {
                await fetchTotalRows(session: session, table: table)
            }

            isLoading = false
        } catch {
            loadError = ErrorClassifier.classify(
                error,
                context: ErrorContext(operation: "loadData", databaseType: databaseType, host: host)
            )
            isLoading = false
        }
    }

    private func buildSelectQuery(table: TableInfo) -> String {
        if hasActiveSearch {
            return SQLBuilder.buildSearchSelect(
                table: table.name, type: databaseType,
                searchText: activeSearchText, searchColumns: searchableColumns(),
                filters: filters, logicMode: filterLogicMode,
                sortState: sortState,
                limit: pagination.pageSize, offset: pagination.currentOffset
            )
        }
        if hasActiveFilters {
            return SQLBuilder.buildFilteredSelect(
                table: table.name, type: databaseType,
                filters: filters, logicMode: filterLogicMode,
                sortState: sortState,
                limit: pagination.pageSize, offset: pagination.currentOffset
            )
        }
        if sortState.isSorting {
            return SQLBuilder.buildSelect(
                table: table.name, type: databaseType,
                sortState: sortState,
                limit: pagination.pageSize, offset: pagination.currentOffset
            )
        }
        return SQLBuilder.buildSelect(
            table: table.name, type: databaseType,
            limit: pagination.pageSize, offset: pagination.currentOffset
        )
    }

    private func searchableColumns() -> [ColumnInfo] {
        columns.filter { col in
            let upper = col.typeName.uppercased()
            return !upper.contains("BLOB") && !upper.contains("BYTEA") && !upper.contains("BINARY")
                && !upper.contains("VARBINARY") && !upper.contains("IMAGE")
        }
    }

    private func fetchTotalRows(session: ConnectionSession, table: TableInfo) async {
        do {
            let countQuery: String
            if hasActiveSearch {
                countQuery = SQLBuilder.buildSearchCount(
                    table: table.name, type: databaseType,
                    searchText: activeSearchText, searchColumns: searchableColumns(),
                    filters: filters, logicMode: filterLogicMode
                )
            } else if hasActiveFilters {
                countQuery = SQLBuilder.buildFilteredCount(
                    table: table.name, type: databaseType,
                    filters: filters, logicMode: filterLogicMode
                )
            } else {
                countQuery = SQLBuilder.buildCount(table: table.name, type: databaseType)
            }
            let countResult = try await session.driver.execute(query: countQuery)
            if let firstRow = countResult.rows.first, let firstCol = firstRow.first {
                pagination.totalRows = Int(firstCol ?? "0")
            }
        } catch {
            Self.logger.warning("Failed to fetch row count: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Pagination

    func goToNextPage() async {
        guard pagination.hasNextPage else { return }
        pagination.currentPage += 1
        await navigatePage()
    }

    func goToPreviousPage() async {
        guard pagination.currentPage > 0 else { return }
        pagination.currentPage -= 1
        await navigatePage()
    }

    func goToPage(_ page: Int) async {
        guard page >= 1 else { return }
        if let total = pagination.totalRows {
            let maxPage = max(1, (total + pagination.pageSize - 1) / pagination.pageSize)
            pagination.currentPage = min(page - 1, maxPage - 1)
        } else {
            pagination.currentPage = page - 1
        }
        await navigatePage()
    }

    func changePageSize(_ size: Int) async {
        pagination.pageSize = size
        pagination.currentPage = 0
        pagination.totalRows = nil
        await navigatePage()
    }

    private func navigatePage() async {
        isPageLoading = true
        await load()
        isPageLoading = false
    }

    // MARK: - Sort / Filter / Search

    func applySort() async {
        pagination.currentPage = 0
        pagination.totalRows = nil
        await load()
    }

    func applySearch(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        activeSearchText = trimmed
        guard !trimmed.isEmpty, !columns.isEmpty else { return }
        pagination.currentPage = 0
        pagination.totalRows = nil
        searchTask?.cancel()
        let task = Task { [weak self] in await self?.load() }
        searchTask = task
        await task.value
    }

    func clearSearch() async {
        activeSearchText = ""
        pagination.currentPage = 0
        pagination.totalRows = nil
        searchTask?.cancel()
        let task = Task { [weak self] in await self?.load() }
        searchTask = task
        await task.value
    }

    func applyFilters() async {
        pagination.currentPage = 0
        pagination.totalRows = nil
        await load()
    }

    func clearFilters() async {
        filters.removeAll()
        pagination.currentPage = 0
        pagination.totalRows = nil
        await load()
    }

    // MARK: - Row Operations

    func deleteRow(pkValues: [(column: String, value: String)]) async -> Bool {
        guard let session, let table, !pkValues.isEmpty else { return false }
        do {
            _ = try await session.driver.execute(
                query: SQLBuilder.buildDelete(table: table.name, type: databaseType, primaryKeys: pkValues)
            )
            await load()
            return true
        } catch {
            operationError = ErrorClassifier.classify(
                error,
                context: ErrorContext(operation: "deleteRow", databaseType: databaseType, host: host)
            )
            return false
        }
    }

    func primaryKeyValues(for row: [String?]) -> [(column: String, value: String)] {
        columnDetails.compactMap { col in
            guard col.isPrimaryKey,
                  let colIndex = columns.firstIndex(where: { $0.name == col.name }),
                  colIndex < row.count,
                  let value = row[colIndex] else { return nil }
            return (column: col.name, value: value)
        }
    }

    // MARK: - Lazy Cell Loading

    func loadFullValue(driver: DatabaseDriver, ref: CellRef) async throws -> String? {
        let predicates = ref.primaryKey.map { component in
            "\"\(component.column.replacingOccurrences(of: "\"", with: "\"\""))\" = '\(component.value.replacingOccurrences(of: "'", with: "''"))'"
        }
        let predicate = predicates.joined(separator: " AND ")
        let column = "\"\(ref.column.replacingOccurrences(of: "\"", with: "\"\""))\""
        let table = "\"\(ref.table.replacingOccurrences(of: "\"", with: "\"\""))\""
        let query = "SELECT \(column) FROM \(table) WHERE \(predicate) LIMIT 1"

        let result = try await driver.execute(query: query)
        return result.rows.first?.first ?? nil
    }

    // MARK: - Memory Pressure

    nonisolated func handlePressure(_ level: MemoryPressureMonitor.Level) async {
        await MainActor.run {
            switch level {
            case .normal:
                break
            case .warning:
                Self.logger.warning("Memory pressure warning: shrinking window to 100 rows")
                self.window.shrink(to: 100)
                self.shrinkLegacyRows(to: 100)
                if !self.legacyRows.isEmpty {
                    self.memoryWarning = String(localized: "Results trimmed due to memory pressure.")
                }
            case .critical:
                Self.logger.error("Memory pressure critical: shrinking window to 50 rows and cancelling")
                self.window.shrink(to: 50)
                self.shrinkLegacyRows(to: 50)
                self.fetchTask?.cancel()
                self.memoryWarning = String(localized: "Results trimmed due to memory pressure.")
            }
        }
    }

    func handleSystemMemoryWarning() async {
        guard !legacyRows.isEmpty else { return }
        Self.logger.warning("System memory warning: shrinking window from \(self.legacyRows.count) rows")
        await handlePressure(.warning)
    }

    func dismissMemoryWarning() {
        memoryWarning = nil
    }

    // MARK: - Streaming (Internal)

    private func loadPage(
        driver: DatabaseDriver,
        query: String,
        lazyContext: LazyContext?,
        pageSize: Int
    ) async {
        fetchTask?.cancel()
        let options = StreamOptions(
            textTruncationBytes: 4_096,
            inlineBinary: false,
            maxRows: pageSize,
            lazyContext: lazyContext
        )
        phase = .loading
        columns = []
        window.clear()
        legacyRows.removeAll(keepingCapacity: true)
        rowsAffected = nil
        statusMessage = nil
        pendingRows.removeAll(keepingCapacity: true)

        let start = Date()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await element in driver.executeStreaming(query: query, options: options) {
                    if Task.isCancelled { break }
                    self.apply(element: element)
                }
                self.flushPendingRows()
                self.executionTime = Date().timeIntervalSince(start)
                if case .loading = self.phase {
                    self.phase = .loaded
                }
            } catch {
                self.flushPendingRows()
                self.phase = .error(self.classify(error: error))
            }
        }
        fetchTask = task
        await task.value
    }

    func cancel() {
        fetchTask?.cancel()
        flushTask?.cancel()
        searchTask?.cancel()
        flushTask = nil
        searchTask = nil
    }

    private func apply(element: StreamElement) {
        switch element {
        case .columns(let cols):
            columns = cols
        case .row(let row):
            pendingRows.append(row)
            scheduleFlushIfNeeded()
        case .rowsAffected(let count):
            flushPendingRows()
            rowsAffected = count
        case .statusMessage(let message):
            flushPendingRows()
            statusMessage = message
        case .truncated(let reason):
            flushPendingRows()
            phase = .truncated(reason: reason)
        }
    }

    private func scheduleFlushIfNeeded() {
        if pendingRows.count >= Self.flushBatchSize {
            flushPendingRows()
            return
        }
        if flushTask == nil {
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: Self.flushInterval)
                guard !Task.isCancelled else { return }
                self?.flushPendingRows()
            }
        }
    }

    private func flushPendingRows() {
        flushTask?.cancel()
        flushTask = nil
        guard !pendingRows.isEmpty else { return }
        let legacyBatch = pendingRows.map(\.legacyValues)
        window.append(contentsOf: pendingRows)
        legacyRows.append(contentsOf: legacyBatch)
        if legacyRows.count > window.count {
            legacyRows.removeFirst(legacyRows.count - window.count)
        }
        pendingRows.removeAll(keepingCapacity: true)
    }

    private func shrinkLegacyRows(to count: Int) {
        guard legacyRows.count > count else { return }
        legacyRows.removeFirst(legacyRows.count - count)
    }

    private func classify(error: Error) -> AppError {
        let context = ErrorContext(operation: "loadPage", databaseType: databaseType)
        return ErrorClassifier.classify(error, context: context)
    }
}
