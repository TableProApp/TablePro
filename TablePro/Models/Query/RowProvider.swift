//
//  RowProvider.swift
//  TablePro
//
//  Protocol for virtualized row data access
//

import Foundation
import os

/// Protocol for virtualized data access with lazy loading support
protocol RowProvider: AnyObject {
    /// Total number of rows available
    var totalRowCount: Int { get }

    /// Column names
    var columns: [String] { get }

    /// Column default values from schema
    var columnDefaults: [String: String?] { get }

    /// Fetch rows for the given range
    /// - Parameters:
    ///   - offset: Starting row index
    ///   - limit: Maximum number of rows to fetch
    /// - Returns: Array of row data
    func fetchRows(offset: Int, limit: Int) -> [TableRowData]

    /// Prefetch rows at specific indices for smoother scrolling
    func prefetchRows(at indices: [Int])

    /// Invalidate cached data (e.g., after refresh)
    func invalidateCache()
}

/// Represents a single row of table data
final class TableRowData {
    let index: Int
    var values: [String?]

    init(index: Int, values: [String?]) {
        self.index = index
        self.values = values
    }

    /// Get value at column index
    func value(at columnIndex: Int) -> String? {
        guard columnIndex < values.count else { return nil }
        return values[columnIndex]
    }

    /// Set value at column index
    func setValue(_ value: String?, at columnIndex: Int) {
        guard columnIndex < values.count else { return }
        values[columnIndex] = value
    }
}

// MARK: - In-Memory Row Provider

/// Row provider that keeps all data in memory as `[[String?]]`.
/// References `RowBuffer` directly to avoid duplicating row data.
/// An optional `sortIndices` array maps display indices to source-row indices,
/// so sorted views don't need a reordered copy of the rows.
///
/// Direct-access methods `value(atRow:column:)` and `rowValues(at:)` avoid
/// heap allocations by reading straight from the source `[String?]` array.
final class InMemoryRowProvider: RowProvider {
    private weak var rowBuffer: RowBuffer?
    /// Strong reference only when the provider created its own buffer (convenience init).
    /// External buffers are owned by QueryTab, so we hold them weakly.
    private var ownedBuffer: RowBuffer?
    private static let emptyBuffer = RowBuffer()
    private var safeBuffer: RowBuffer { rowBuffer ?? Self.emptyBuffer }
    private var sortIndices: [Int]?
    private var appendedRows: [[String?]] = []
    private(set) var columns: [String]

    /// Lazy per-cell cache for formatted display values.
    /// Keyed by source row index (buffer index or offset appended index).
    private var displayCache: [Int: [String?]] = [:]
    private(set) var columnDefaults: [String: String?]
    private(set) var columnTypes: [ColumnType]
    private(set) var columnForeignKeys: [String: ForeignKeyInfo]
    private(set) var columnEnumValues: [String: [String]]
    private(set) var columnNullable: [String: Bool]

    var totalRowCount: Int {
        bufferRowCount + appendedRows.count
    }

    /// Number of rows coming from the buffer (respecting sort indices count when present)
    private var bufferRowCount: Int {
        sortIndices?.count ?? safeBuffer.rows.count
    }

    init(
        rowBuffer: RowBuffer,
        sortIndices: [Int]? = nil,
        columns: [String],
        columnDefaults: [String: String?] = [:],
        columnTypes: [ColumnType]? = nil,
        columnForeignKeys: [String: ForeignKeyInfo] = [:],
        columnEnumValues: [String: [String]] = [:],
        columnNullable: [String: Bool] = [:]
    ) {
        self.rowBuffer = rowBuffer
        self.sortIndices = sortIndices
        self.columns = columns
        self.columnDefaults = columnDefaults
        self.columnTypes = columnTypes ?? Array(repeating: ColumnType.text(rawType: nil), count: columns.count)
        self.columnForeignKeys = columnForeignKeys
        self.columnEnumValues = columnEnumValues
        self.columnNullable = columnNullable
    }

    /// Convenience initializer that wraps rows in an internal RowBuffer.
    /// Used by tests, previews, and callers that don't have a RowBuffer reference.
    convenience init(
        rows: [[String?]],
        columns: [String],
        columnDefaults: [String: String?] = [:],
        columnTypes: [ColumnType]? = nil,
        columnForeignKeys: [String: ForeignKeyInfo] = [:],
        columnEnumValues: [String: [String]] = [:],
        columnNullable: [String: Bool] = [:]
    ) {
        let buffer = RowBuffer(rows: rows, columns: columns)
        self.init(
            rowBuffer: buffer,
            columns: columns,
            columnDefaults: columnDefaults,
            columnTypes: columnTypes,
            columnForeignKeys: columnForeignKeys,
            columnEnumValues: columnEnumValues,
            columnNullable: columnNullable
        )
        ownedBuffer = buffer
    }

    func fetchRows(offset: Int, limit: Int) -> [TableRowData] {
        let total = totalRowCount
        let endIndex = min(offset + limit, total)
        guard offset < endIndex else { return [] }
        var result: [TableRowData] = []
        result.reserveCapacity(endIndex - offset)
        for i in offset..<endIndex {
            result.append(TableRowData(index: i, values: sourceRow(at: i)))
        }
        return result
    }

    func prefetchRows(at indices: [Int]) {
        // No-op for in-memory provider - all data already available
    }

    func invalidateCache() {
        displayCache.removeAll()
    }

    /// Update a cell value
    func updateValue(_ value: String?, at rowIndex: Int, columnIndex: Int) {
        guard rowIndex < totalRowCount else { return }
        let sourceIndex = resolveSourceIndex(rowIndex)
        if let bufferIdx = sourceIndex.bufferIndex {
            guard let buffer = rowBuffer else { return }
            buffer.rows[bufferIdx][columnIndex] = value
            displayCache.removeValue(forKey: bufferIdx)
        } else if let appendedIdx = sourceIndex.appendedIndex {
            appendedRows[appendedIdx][columnIndex] = value
            displayCache.removeValue(forKey: bufferRowCount + appendedIdx)
        }
    }

    /// Get row data at index
    func row(at index: Int) -> TableRowData? {
        guard index >= 0 && index < totalRowCount else { return nil }
        return TableRowData(index: index, values: sourceRow(at: index))
    }

    /// O(1) cell value access — no heap allocation.
    func value(atRow rowIndex: Int, column columnIndex: Int) -> String? {
        guard rowIndex >= 0 && rowIndex < totalRowCount else { return nil }
        let src = sourceRow(at: rowIndex)
        guard columnIndex >= 0 && columnIndex < src.count else { return nil }
        return src[columnIndex]
    }

    /// Returns the source values array for a display row. No copy until caller stores it.
    func rowValues(at rowIndex: Int) -> [String?]? {
        guard rowIndex >= 0 && rowIndex < totalRowCount else { return nil }
        return sourceRow(at: rowIndex)
    }

    // MARK: - Display Value Cache

    /// Get the formatted display value for a cell.
    /// Computes on first access for the entire row, returns cached on subsequent calls.
    @MainActor
    func displayValue(atRow rowIndex: Int, column columnIndex: Int) -> String? {
        guard rowIndex >= 0 && rowIndex < totalRowCount else { return nil }

        let cacheKey = resolveCacheKey(for: rowIndex)

        if let cachedRow = displayCache[cacheKey], columnIndex < cachedRow.count {
            return cachedRow[columnIndex]
        }

        let src = sourceRow(at: rowIndex)
        let columnCount = columns.count
        var rowCache = [String?](repeating: nil, count: columnCount)
        for col in 0..<min(src.count, columnCount) {
            let ct = col < columnTypes.count ? columnTypes[col] : nil
            rowCache[col] = CellDisplayFormatter.format(src[col], columnType: ct)
        }
        displayCache[cacheKey] = rowCache
        return columnIndex < rowCache.count ? rowCache[columnIndex] : nil
    }

    /// Invalidate entire display cache (after settings change, full reload).
    func invalidateDisplayCache() {
        displayCache.removeAll()
    }

    /// Release cached data to free memory when this provider is no longer active.
    func releaseData() {
        displayCache.removeAll()
        appendedRows.removeAll()
        sortIndices = nil
        ownedBuffer = nil
    }

    /// Update rows by replacing the buffer contents and clearing appended rows
    func updateRows(_ newRows: [[String?]]) {
        guard let buffer = rowBuffer else { return }
        buffer.rows = newRows
        appendedRows.removeAll()
        sortIndices = nil
        displayCache.removeAll()
    }

    /// Append a new row with given values
    /// Returns the index of the new row
    func appendRow(values: [String?]) -> Int {
        let newIndex = totalRowCount
        appendedRows.append(values)
        return newIndex
    }

    /// Remove row at index (used when discarding new rows)
    func removeRow(at index: Int) {
        guard index >= 0 && index < totalRowCount else { return }
        let bCount = bufferRowCount
        if index >= bCount {
            let appendedIdx = index - bCount
            guard appendedIdx < appendedRows.count else { return }
            appendedRows.remove(at: appendedIdx)
        } else {
            guard let buffer = rowBuffer else { return }
            if let sorted = sortIndices {
                let bufferIdx = sorted[index]
                buffer.rows.remove(at: bufferIdx)
                var newIndices = sorted
                newIndices.remove(at: index)
                for i in newIndices.indices where newIndices[i] > bufferIdx {
                    newIndices[i] -= 1
                }
                sortIndices = newIndices
            } else {
                buffer.rows.remove(at: index)
            }
        }
        displayCache.removeAll()
    }

    /// Remove multiple rows at indices (used when discarding new rows)
    /// Indices should be sorted in descending order to maintain correct removal
    func removeRows(at indices: Set<Int>) {
        for index in indices.sorted(by: >) {
            guard index >= 0 && index < totalRowCount else { continue }
            removeRow(at: index)
        }
    }

    // MARK: - Private

    /// Map a display index to a cache key based on the source row identity.
    private func resolveCacheKey(for displayIndex: Int) -> Int {
        let sourceIdx = resolveSourceIndex(displayIndex)
        if let bufIdx = sourceIdx.bufferIndex {
            return bufIdx
        } else if let appIdx = sourceIdx.appendedIndex {
            return bufferRowCount + appIdx
        }
        return displayIndex
    }

    /// Resolve a display index to either a buffer index or an appended-row index.
    private func resolveSourceIndex(_ displayIndex: Int) -> (bufferIndex: Int?, appendedIndex: Int?) {
        let bCount = bufferRowCount
        if displayIndex >= bCount {
            return (nil, displayIndex - bCount)
        }
        if let sorted = sortIndices {
            return (sorted[displayIndex], nil)
        }
        return (displayIndex, nil)
    }

    /// Get the source row values for a display index.
    private func sourceRow(at displayIndex: Int) -> [String?] {
        let bCount = bufferRowCount
        if displayIndex >= bCount {
            return appendedRows[displayIndex - bCount]
        }
        if let sorted = sortIndices {
            return safeBuffer.rows[sorted[displayIndex]]
        }
        return safeBuffer.rows[displayIndex]
    }
}

// MARK: - Database Row Provider (for virtualized access via driver)

/// Row provider that fetches data on-demand from database.
/// Cache is bounded to `maxCacheSize` entries; oldest entries by row index
/// are evicted when the limit is exceeded.
final class DatabaseRowProvider: RowProvider {
    private static let logger = Logger(subsystem: "com.TablePro", category: "RowProvider")
    private static let maxCacheSize = 10_000

    private let driver: DatabaseDriver
    private let baseQuery: String
    private var cache: [Int: TableRowData] = [:]
    private let pageSize: Int
    private var prefetchTask: Task<Void, Never>?
    private var inFlightRange: Range<Int>?

    private(set) var totalRowCount: Int = 0
    private(set) var columns: [String]
    private(set) var columnDefaults: [String: String?]

    private var isInitialized = false

    init(driver: DatabaseDriver, query: String, columns: [String], columnDefaults: [String: String?] = [:], pageSize: Int = 200) {
        self.driver = driver
        self.baseQuery = query
        self.columns = columns
        self.columnDefaults = columnDefaults
        self.pageSize = pageSize
    }

    /// Initialize by fetching total row count
    func initialize() async throws {
        guard !isInitialized else { return }

        totalRowCount = try await driver.fetchRowCount(query: baseQuery)
        isInitialized = true
    }

    func fetchRows(offset: Int, limit: Int) -> [TableRowData] {
        var result: [TableRowData] = []

        for i in offset..<min(offset + limit, totalRowCount) {
            if let cached = cache[i] {
                result.append(cached)
            } else {
                // Return placeholder - actual data filled via prefetch
                let placeholder = TableRowData(index: i, values: Array(repeating: "...", count: columns.count))
                result.append(placeholder)
            }
        }

        return result
    }

    func prefetchRows(at indices: [Int]) {
        let missingIndices = indices.filter { cache[$0] == nil }
        guard !missingIndices.isEmpty else { return }

        guard let minIndex = missingIndices.min(),
              let maxIndex = missingIndices.max() else { return }

        let offset = minIndex
        let limit = min(maxIndex - minIndex + pageSize, totalRowCount - offset)
        let fetchRange = offset..<(offset + limit)

        if let inFlight = inFlightRange,
           inFlight.contains(offset) && inFlight.contains(offset + limit - 1) {
            return
        }

        prefetchTask?.cancel()
        let driver = self.driver
        let baseQuery = self.baseQuery

        inFlightRange = fetchRange
        prefetchTask = Task { [weak self] in
            do {
                let result = try await driver.fetchRows(query: baseQuery, offset: offset, limit: limit)
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    for (i, row) in result.rows.enumerated() {
                        self.cache[offset + i] = TableRowData(index: offset + i, values: row)
                    }
                    self.evictCacheIfNeeded(nearIndex: offset)
                    self.inFlightRange = nil
                }
            } catch {
                guard !Task.isCancelled else { return }
                Self.logger.error("Prefetch error: \(error)")
                await MainActor.run { [weak self] in
                    self?.inFlightRange = nil
                }
            }
        }
    }

    func invalidateCache() {
        prefetchTask?.cancel()
        prefetchTask = nil
        inFlightRange = nil
        cache.removeAll()
        isInitialized = false
    }

    /// Synchronously fetch and cache rows (for initial load)
    func loadRows(offset: Int, limit: Int) async throws {
        let result = try await driver.fetchRows(query: baseQuery, offset: offset, limit: limit)
        for (i, row) in result.rows.enumerated() {
            let rowData = TableRowData(index: offset + i, values: row)
            cache[offset + i] = rowData
        }
        evictCacheIfNeeded(nearIndex: offset)
    }

    /// Get row data at index (nil if not cached)
    func row(at index: Int) -> TableRowData? {
        cache[index]
    }

    /// Update a cached cell value
    func updateValue(_ value: String?, at rowIndex: Int, columnIndex: Int) {
        cache[rowIndex]?.setValue(value, at: columnIndex)
    }

    // MARK: - Private

    /// Evict entries when cache exceeds `maxCacheSize`.
    /// Keeps the half of entries closest to `nearIndex` (the current access window)
    /// and discards the rest.
    private func evictCacheIfNeeded(nearIndex: Int) {
        guard cache.count > Self.maxCacheSize else { return }
        let halfSize = Self.maxCacheSize / 2
        cache = cache.filter { abs($0.key - nearIndex) <= halfSize }
    }
}
