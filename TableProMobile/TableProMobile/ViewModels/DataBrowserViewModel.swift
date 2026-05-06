//
//  DataBrowserViewModel.swift
//  TableProMobile
//

import Foundation
import os
import TableProDatabase
import TableProModels

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

    @ObservationIgnored private var pendingRows: [Row] = []
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var fetchTask: Task<Void, Never>?

    private static let flushBatchSize = 200
    private static let flushInterval: Duration = .milliseconds(50)

    init(windowCapacity: Int = 1_000) {
        self.window = RowWindow(capacity: windowCapacity)
    }

    func loadPage(
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
        flushTask = nil
    }

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

    nonisolated func handlePressure(_ level: MemoryPressureMonitor.Level) async {
        await MainActor.run {
            switch level {
            case .normal:
                break
            case .warning:
                Self.logger.warning("Memory pressure warning: shrinking window to 100 rows")
                self.window.shrink(to: 100)
                self.shrinkLegacyRows(to: 100)
            case .critical:
                Self.logger.error("Memory pressure critical: shrinking window to 50 rows and cancelling")
                self.window.shrink(to: 50)
                self.shrinkLegacyRows(to: 50)
                self.fetchTask?.cancel()
            }
        }
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
        let context = ErrorContext(operation: "loadPage")
        return ErrorClassifier.classify(error, context: context)
    }
}
