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

    private let buffer: StreamingResultBuffer
    private(set) var totalRows: Int?
    private(set) var phase: Phase = .idle
    private(set) var executionTime: TimeInterval = 0

    var columns: [ColumnInfo] { buffer.columns }
    var window: RowWindow { buffer.window }
    var legacyRows: [[String?]] { buffer.legacyRows }
    var rowsAffected: Int? { buffer.rowsAffected }
    var statusMessage: String? { buffer.statusMessage }

    private(set) var columnDetails: [ColumnInfo] = []
    private(set) var foreignKeys: [ForeignKeyInfo] = []
    private(set) var pagination: PaginationState
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
    /// The schema the rows on screen were fetched with. Every statement the browser and its
    /// children issue reads this one value, so an edit cannot target a schema the visible rows did
    /// not come from.
    private(set) var schema: String?
    @ObservationIgnored private var host: String = ""
    @ObservationIgnored private var trackRead: SessionReadTracker?
    @ObservationIgnored private var pageEndedOnItsOwn = false
    @ObservationIgnored private var pageWasTrimmed = false
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var keyReadTask: Task<KeyContentsPage, Error>?
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var hasSeededFilters = false
    @ObservationIgnored private var singleRowMatch = SingleRowMatch.inactive

    private enum SingleRowMatch {
        case inactive
        case awaitingFirstLoad
        case found
    }

    init(windowCapacity: Int = 1_000) {
        self.buffer = StreamingResultBuffer(capacity: windowCapacity)
        self.pagination = PaginationState(pageSize: AppPreferences.defaultPageSize, currentPage: 0)
    }

    // MARK: - Computed

    var hasActiveSearch: Bool { !activeSearchText.isEmpty }
    var hasActiveFilters: Bool { filters.contains { $0.isEnabled && $0.isValid } }
    var activeFilterCount: Int { filters.filter { $0.isEnabled && $0.isValid }.count }
    var hasPrimaryKeys: Bool { columnDetails.contains(where: \.isPrimaryKey) }

    var canLocateRows: Bool {
        RowLocator.canLocate(identity: rowIdentity, columns: columns, columnDetails: columnDetails)
    }

    private var rowIdentity: RowIdentity { RowLocator.identity(of: session?.driver) }

    var showsPaginationBar: Bool {
        !legacyRows.isEmpty || hasActiveSearch || hasActiveFilters || isPageLoading
    }

    var canGoToPreviousPage: Bool { pagination.currentPage > 0 && !isLoading }
    var canGoToNextPage: Bool { pagination.hasNextPage && !isLoading }

    var paginationLabel: String {
        guard !legacyRows.isEmpty else { return "" }
        let start = pagination.currentOffset + 1
        let end = pagination.currentOffset + legacyRows.count
        guard let total = pagination.totalRows else { return "\(start)-\(end)" }
        return Self.pageRangeLabel(start: start, end: end, total: total)
    }

    nonisolated static func pageRangeLabel(start: Int, end: Int, total: Int, bundle: Bundle = .main) -> String {
        String(format: String(localized: "%1$lld-%2$lld of %3$lld", bundle: bundle), start, end, total)
    }

    // MARK: - Attach

    typealias SessionReadTracker = @MainActor (_ read: () async -> Void) async -> Void

    // `trackRead` marks the session busy for the whole load, so Commit and Roll Back cannot end a page mid-stream.
    func attach(
        session: ConnectionSession?,
        table: TableInfo,
        databaseType: DatabaseType,
        host: String,
        schema: String? = nil,
        trackRead: SessionReadTracker? = nil
    ) {
        self.session = session
        self.table = table
        self.databaseType = databaseType
        self.host = host
        self.schema = schema
        self.trackRead = trackRead
    }

    // Only the first call counts, so filters the user changed afterwards survive the view's task running again.
    func seedFilters(_ seeded: [TableFilter]) {
        guard !hasSeededFilters else { return }
        hasSeededFilters = true
        filters = seeded
        filterLogicMode = .and
        singleRowMatch = hasActiveFilters ? .awaitingFirstLoad : .inactive
    }

    func takeSingleRowMatch() -> Bool {
        guard case .found = singleRowMatch else { return false }
        singleRowMatch = .inactive
        return true
    }

    // MARK: - Load

    func load(isInitial: Bool = false) async {
        loadGeneration += 1
        let generation = loadGeneration

        guard let session, let table else {
            loadError = AppError(
                category: .config,
                title: String(localized: "Not Connected"),
                message: String(localized: "No active database session."),
                recovery: String(localized: "Go back and reconnect to the database."),
                underlying: nil
            )
            finishLoad()
            return
        }

        if isInitial || legacyRows.isEmpty {
            isLoading = true
        } else {
            isPageLoading = true
        }
        loadError = nil

        await tracked {
            if let reader = TableBrowseMode.keyContentsReader(of: session.driver) {
                await loadKeyContents(reader: reader, key: table.name, generation: generation)
            } else {
                await loadRows(session: session, table: table, isInitial: isInitial, generation: generation)
            }
        }
        guard isCurrent(generation) else { return }
        finishLoad()
    }

    private func tracked(_ read: () async -> Void) async {
        guard let trackRead else {
            await read()
            return
        }
        await trackRead(read)
    }

    private func isCurrent(_ generation: Int) -> Bool {
        generation == loadGeneration
    }

    private func finishLoad() {
        isLoading = false
        isPageLoading = false
        guard case .awaitingFirstLoad = singleRowMatch else { return }
        singleRowMatch = loadError == nil && legacyRows.count == 1 ? .found : .inactive
    }

    private func loadRows(session: ConnectionSession, table: TableInfo, isInitial: Bool, generation: Int) async {
        do {
            if columnDetails.isEmpty || isInitial {
                let fetched = try await session.driver.fetchColumns(table: table.name, schema: schema)
                guard isCurrent(generation) else { return }
                columnDetails = fetched
            }

            // A full value read by key would return another row's value where the key is not unique.
            let pkColumns = rowIdentity == .keyColumns ? columnDetails.filter(\.isPrimaryKey).map(\.name) : []
            let lazyContext = pkColumns.isEmpty ? nil : LazyContext(table: table.name, primaryKeyColumns: pkColumns)
            let driver = session.driver
            let query = (driver as? any DriverQueryBuilding).map { builder in
                builder.pageQuery(readRequest(table: table), limit: pagination.pageSize, offset: pagination.currentOffset)
            } ?? buildSelectQuery(table: table)

            await loadPage(
                options: pageOptions(lazyContext: lazyContext), startedAt: Date(), generation: generation
            ) { options in
                driver.executeStreaming(query: query, options: options)
            }
            guard isCurrent(generation) else { return }

            if case .error(let err) = phase {
                loadError = err
                return
            }
            settleTotalRowsFromShortPage()

            if foreignKeys.isEmpty || isInitial {
                do {
                    let fetched = try await session.driver.fetchForeignKeys(table: table.name, schema: schema)
                    guard isCurrent(generation) else { return }
                    foreignKeys = fetched
                } catch {
                    Self.logger.warning("Failed to fetch foreign keys: \(error.localizedDescription, privacy: .private)")
                }
            }

            if isCurrent(generation), pagination.totalRows == nil {
                await fetchTotalRows(session: session, table: table, generation: generation)
            }
        } catch {
            guard isCurrent(generation) else { return }
            loadError = ErrorClassifier.classify(
                error,
                context: ErrorContext(operation: "loadData", databaseType: databaseType, host: host)
            )
        }
    }

    private func loadKeyContents(reader: any KeyContentsBrowsing, key: String, generation: Int) async {
        let start = Date()
        let limit = pagination.pageSize
        let offset = pagination.currentOffset
        keyReadTask?.cancel()
        let read = Task { try await reader.keyContentsPage(ofKey: key, limit: limit, offset: offset) }
        keyReadTask = read
        do {
            let page = try await read.value
            guard keyReadTask == read, !read.isCancelled, isCurrent(generation) else { return }
            columnDetails = page.result.columns
            foreignKeys = []
            pagination.totalRows = page.totalCount

            let result = page.result
            await loadPage(options: pageOptions(lazyContext: nil), startedAt: start, generation: generation) { options in
                QueryResultStreaming.stream(options: options) { result }
            }
            guard isCurrent(generation) else { return }

            if case .error(let err) = phase {
                loadError = err
                return
            }
            settleTotalRowsFromShortPage()
        } catch {
            guard keyReadTask == read, !read.isCancelled, isCurrent(generation) else { return }
            loadError = ErrorClassifier.classify(
                error,
                context: ErrorContext(operation: "loadKeyContents", databaseType: databaseType, host: host)
            )
        }
    }

    // A page cut short by Stop, a closed screen or another statement says nothing about where the table ends.
    private func settleTotalRowsFromShortPage() {
        guard pageEndedOnItsOwn, legacyRows.count < pagination.pageSize, pagination.totalRows == nil else { return }
        pagination.totalRows = pagination.currentOffset + legacyRows.count
    }

    private func pageOptions(lazyContext: LazyContext?) -> StreamOptions {
        StreamOptions(
            textTruncationBytes: 4_096,
            inlineBinary: false,
            maxRows: pagination.pageSize,
            lazyContext: lazyContext
        )
    }

    private func buildSelectQuery(table: TableInfo) -> String {
        let activeSort = effectiveSortState()
        if hasActiveSearch {
            return SQLBuilder.buildSearchSelect(
                table: table.name, schema: schema, type: databaseType,
                searchText: activeSearchText, searchColumns: searchableColumns(),
                filters: filters, logicMode: filterLogicMode, columns: columnDetails,
                sortState: activeSort,
                limit: pagination.pageSize, offset: pagination.currentOffset
            )
        }
        if hasActiveFilters {
            return SQLBuilder.buildFilteredSelect(
                table: table.name, schema: schema, type: databaseType,
                filters: filters, logicMode: filterLogicMode, columns: columnDetails,
                sortState: activeSort,
                limit: pagination.pageSize, offset: pagination.currentOffset
            )
        }
        if activeSort.isSorting {
            return SQLBuilder.buildSelect(
                table: table.name, schema: schema, type: databaseType,
                sortState: activeSort,
                limit: pagination.pageSize, offset: pagination.currentOffset
            )
        }
        return SQLBuilder.buildSelect(
            table: table.name, schema: schema, type: databaseType,
            limit: pagination.pageSize, offset: pagination.currentOffset
        )
    }

    /// SQL Server's `OFFSET FETCH` requires `ORDER BY`. When the user has not picked an explicit
    /// sort, inject a stable order (first primary-key column, falling back to the first column)
    /// so paging is deterministic across requests. Other databases tolerate an empty ORDER BY.
    private func effectiveSortState() -> SortState {
        if sortState.isSorting { return sortState }
        guard databaseType == .mssql || databaseType == .oracle else { return sortState }
        let fallback = columnDetails.first(where: \.isPrimaryKey)?.name ?? columnDetails.first?.name
        guard let fallback else { return sortState }
        return SortState(columns: [SortColumn(name: fallback, ascending: true)])
    }

    private func readRequest(table: TableInfo) -> TableReadRequest {
        TableReadRequest(
            table: table.name,
            schema: schema,
            filters: filters.filter { $0.isEnabled && $0.isValid },
            logicMode: filterLogicMode,
            searchText: hasActiveSearch ? activeSearchText : nil,
            searchColumns: searchableColumns().map(\.name),
            sortState: sortState
        )
    }

    private func searchableColumns() -> [ColumnInfo] {
        columns.filter { col in
            let upper = col.typeName.uppercased()
            return !upper.contains("BLOB") && !upper.contains("BYTEA") && !upper.contains("BINARY")
                && !upper.contains("VARBINARY") && !upper.contains("IMAGE")
        }
    }

    private func fetchTotalRows(session: ConnectionSession, table: TableInfo, generation: Int) async {
        do {
            if let builder = session.driver as? any DriverQueryBuilding {
                let total = try await builder.rowCount(readRequest(table: table))
                guard isCurrent(generation) else { return }
                pagination.totalRows = total
                return
            }
            let countQuery: String
            if hasActiveSearch {
                countQuery = SQLBuilder.buildSearchCount(
                    table: table.name, schema: schema, type: databaseType,
                    searchText: activeSearchText, searchColumns: searchableColumns(),
                    filters: filters, logicMode: filterLogicMode, columns: columnDetails
                )
            } else if hasActiveFilters {
                countQuery = SQLBuilder.buildFilteredCount(
                    table: table.name, schema: schema, type: databaseType,
                    filters: filters, logicMode: filterLogicMode, columns: columnDetails
                )
            } else {
                countQuery = SQLBuilder.buildCount(table: table.name, schema: schema, type: databaseType)
            }
            let countResult = try await session.driver.execute(query: countQuery)
            guard isCurrent(generation) else { return }
            if let firstRow = countResult.rows.first, let firstCol = firstRow.first {
                pagination.totalRows = Int(firstCol ?? "0")
            }
        } catch {
            Self.logger.warning("Failed to fetch row count: \(error.localizedDescription, privacy: .private)")
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
        await load()
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
        let task = Task { [weak self] in
            guard let self else { return }
            await self.load()
        }
        searchTask = task
        await task.value
    }

    func clearSearch() async {
        activeSearchText = ""
        pagination.currentPage = 0
        pagination.totalRows = nil
        searchTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.load()
        }
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

    func deleteRow(_ locator: RowLocator) async -> Bool {
        guard let session, let table else { return false }
        let schema = schema
        if let keys = locator.keyValues, let shared = await SharedRowKey.error(
            table: table.name, schema: schema, key: keys,
            columns: columnDetails, type: databaseType, driver: session.driver
        ) {
            operationError = shared
            return false
        }
        let writer = session.driver as? any DriverRowWriting
        if let writer, let identical = await SharedRowKey.identicalRowsError(
            writer: writer, table: table.name, schema: schema, locator: locator,
            columns: locator.columnNames(of: columns), type: databaseType, isUpdate: false
        ) {
            operationError = identical
            return false
        }
        do {
            guard let batch = try RowWriteBatch.delete(
                table: table.name,
                schema: schema,
                type: databaseType,
                driver: session.driver,
                columns: locator.columnNames(of: columns),
                columnDetails: columnDetails,
                locator: locator
            ) else { return false }
            let deleted = try await batch.run()
            // SQL Server under SET NOCOUNT ON reports 0 for every delete, so a zero is checked against the table.
            // A ClickHouse mutation reports no count, so the row is looked for by every value it held.
            var isGone = deleted > 0
            if !isGone, let keys = locator.keyValues, !keys.isEmpty {
                isGone = try await !rowExists(table: table.name, schema: schema, primaryKey: keys, driver: session.driver)
            } else if !isGone, let writer {
                isGone = try await writer.matchingRowCount(
                    table: table.name, schema: schema, columns: locator.columnNames(of: columns), row: locator.row
                ) == 0
            }
            await load()
            guard isGone else {
                operationError = AppError(
                    category: .query,
                    title: String(localized: "Row Not Deleted"),
                    message: String(localized: "The row is still in the table. A trigger, rule or row security policy may have stopped the delete."),
                    recovery: nil,
                    underlying: nil
                )
                return false
            }
            return true
        } catch RowChangeRefusal.rowNotFound {
            await load()
            return true
        } catch let refusal as RowChangeRefusal {
            operationError = SharedRowKey.error(for: refusal)
            return false
        } catch {
            operationError = ErrorClassifier.classify(
                error,
                context: ErrorContext(operation: "deleteRow", databaseType: databaseType, host: host)
            )
            return false
        }
    }

    func cells(at index: Int) -> [Cell] {
        let rows = window.rows
        return rows.indices.contains(index) ? rows[index].cells : []
    }

    func rowLocator(forRowAt index: Int) -> RowLocator? {
        let rows = window.rows
        guard rows.indices.contains(index) else { return nil }
        return RowLocator.locate(
            cells: rows[index].cells, columns: columns, columnDetails: columnDetails, identity: rowIdentity
        )
    }

    // MARK: - Lazy Cell Loading

    private func rowExists(
        table: String,
        schema: String?,
        primaryKey: [(column: String, value: String)],
        driver: any DatabaseDriver
    ) async throws -> Bool {
        let components = primaryKey.map { PrimaryKeyComponent(column: $0.column, value: $0.value) }
        let ref = CellRef(table: table, column: components[0].column, primaryKey: components)
        do {
            _ = try await readValue(driver: driver, ref: ref, databaseType: databaseType, schema: schema, ofOneRow: false)
            return true
        } catch CellLookupError.rowNotFound {
            return false
        }
    }

    // The caller passes the schema its rows came from: a schema switch while a read is in flight must not move it.
    func loadFullValue(driver: DatabaseDriver, ref: CellRef, databaseType: DatabaseType, schema: String?) async throws -> String? {
        try await readValue(driver: driver, ref: ref, databaseType: databaseType, schema: schema, ofOneRow: true)
    }

    // A full value is read only from a key that names one row; whether a deleted row is still there is not.
    private func readValue(
        driver: DatabaseDriver, ref: CellRef, databaseType: DatabaseType, schema: String?, ofOneRow: Bool
    ) async throws -> String? {
        if let builder = driver as? any DriverQueryBuilding {
            return try await builder.storedValue(
                table: ref.table,
                schema: schema,
                column: ref.column,
                key: ref.primaryKey.map { (column: $0.column, value: $0.value) }
            )
        }
        let table = SQLBuilder.qualifiedIdentifier(table: ref.table, schema: schema, for: databaseType)
        let predicate = SQLBuilder.keyPredicate(
            ref.primaryKey.map { (column: $0.column, value: $0.value) },
            columns: columnDetails,
            type: databaseType,
            driver: driver,
            uniqueIn: ofOneRow ? table : nil
        )
        let column = SQLBuilder.quoteIdentifier(ref.column, for: databaseType)
        let query: String
        switch databaseType {
        case .mssql:
            query = "SELECT TOP 1 \(column) FROM \(table) WHERE \(predicate)"
        case .oracle:
            query = "SELECT \(column) FROM \(table) WHERE \(predicate) FETCH FIRST 1 ROWS ONLY"
        default:
            query = "SELECT \(column) FROM \(table) WHERE \(predicate) LIMIT 1"
        }

        let result = try await driver.execute(query: query)
        guard let row = result.rows.first else { throw CellLookupError.rowNotFound }
        return row.first ?? nil
    }

    nonisolated static func canComplete(_ cells: [Cell]) -> Bool {
        cells.allSatisfy { cell in
            switch cell {
            case .null, .text: true
            case .truncatedText(_, _, let ref): ref != nil
            case .binary: false
            }
        }
    }

    func completeRows(_ rows: [[Cell]], driver: any DatabaseDriver) async throws -> [[Cell]] {
        let pendingBytes = rows.joined().reduce(0) { total, cell in
            guard case .truncatedText(_, let bytes, _?) = cell else { return total }
            return total + bytes
        }
        guard Self.exportFits(
            pendingBytes: pendingBytes,
            availableBytes: MemoryPressureMonitor.shared.availableMemoryBytes()
        ) else {
            throw ClipboardExporter.TooLarge()
        }
        let schema = schema
        var complete: [[Cell]] = []
        complete.reserveCapacity(rows.count)
        for cells in rows {
            var row = cells
            for (index, cell) in cells.enumerated() {
                guard case .truncatedText(_, _, let ref?) = cell else { continue }
                try Task.checkCancellation()
                let value = try await loadFullValue(driver: driver, ref: ref, databaseType: databaseType, schema: schema)
                row[index] = value.map(Cell.text) ?? .null
            }
            complete.append(row)
        }
        return complete
    }

    // The full values, the export text and the pasteboard's copy of it are all held at once.
    nonisolated static func exportFits(pendingBytes: Int, availableBytes: Int) -> Bool {
        guard pendingBytes > 0, availableBytes > 0 else { return true }
        let (copies, overflow) = pendingBytes.multipliedReportingOverflow(by: 4)
        return !overflow && availableBytes - exportMemoryMarginBytes > copies
    }

    private nonisolated static let exportMemoryMarginBytes = 64 * 1_024 * 1_024

    // MARK: - Memory Pressure

    nonisolated func handlePressure(_ level: MemoryPressureMonitor.Level) async {
        await MainActor.run {
            switch level {
            case .normal:
                break
            case .warning:
                Self.logger.warning("Memory pressure warning: shrinking window to 100 rows")
                self.buffer.shrink(to: 100)
                self.pageWasTrimmed = true
                if !self.buffer.isEmpty {
                    self.memoryWarning = String(localized: "Results trimmed due to memory pressure.")
                }
            case .critical:
                Self.logger.error("Memory pressure critical: shrinking window to 50 rows and cancelling")
                self.buffer.shrink(to: 50)
                self.pageWasTrimmed = true
                self.fetchTask?.cancel()
                self.memoryWarning = String(localized: "Results trimmed due to memory pressure.")
            }
        }
    }

    func handleSystemMemoryWarning() async {
        guard !buffer.isEmpty else { return }
        Self.logger.warning("System memory warning: shrinking window from \(self.buffer.count) rows")
        await handlePressure(.warning)
    }

    func dismissMemoryWarning() {
        memoryWarning = nil
    }

    // MARK: - Streaming (Internal)

    private func loadPage(
        options: StreamOptions,
        startedAt start: Date,
        generation: Int,
        stream makeStream: @escaping @Sendable (StreamOptions) -> AsyncThrowingStream<StreamElement, Error>
    ) async {
        fetchTask?.cancel()
        phase = .loading
        buffer.reset()
        pageEndedOnItsOwn = false
        pageWasTrimmed = false

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await element in makeStream(options) {
                    if Task.isCancelled { break }
                    self.buffer.apply(element)
                }
                guard self.isCurrent(generation) else { return }
                self.buffer.flush()
                self.executionTime = Date().timeIntervalSince(start)
                self.pageEndedOnItsOwn = !Task.isCancelled && self.buffer.truncation == nil && !self.pageWasTrimmed
                if let reason = self.buffer.truncation {
                    self.phase = .truncated(reason: reason)
                } else if case .loading = self.phase {
                    self.phase = .loaded
                }
            } catch {
                guard self.isCurrent(generation) else { return }
                self.buffer.flush()
                self.phase = .error(self.classify(error: error))
            }
        }
        fetchTask = task
        await task.value
    }

    func cancel() {
        keyReadTask?.cancel()
        fetchTask?.cancel()
        buffer.cancelFlush()
        searchTask?.cancel()
        searchTask = nil
    }

    private func classify(error: Error) -> AppError {
        let context = ErrorContext(operation: "loadPage", databaseType: databaseType)
        return ErrorClassifier.classify(error, context: context)
    }
}
