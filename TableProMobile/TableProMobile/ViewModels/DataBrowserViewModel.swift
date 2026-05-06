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
    private(set) var totalRows: Int?
    private(set) var phase: Phase = .idle
    private(set) var rowsAffected: Int?
    private(set) var statusMessage: String?
    private(set) var executionTime: TimeInterval = 0

    private var fetchTask: Task<Void, Never>?

    init(windowCapacity: Int = 200) {
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
        rowsAffected = nil
        statusMessage = nil

        let start = Date()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await element in driver.executeStreaming(query: query, options: options) {
                    if Task.isCancelled { break }
                    self.apply(element: element)
                }
                self.executionTime = Date().timeIntervalSince(start)
                if case .loading = self.phase {
                    self.phase = .loaded
                }
            } catch {
                self.phase = .error(self.classify(error: error))
            }
        }
        fetchTask = task
        await task.value
    }

    func cancel() {
        fetchTask?.cancel()
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
            case .critical:
                Self.logger.error("Memory pressure critical: shrinking window to 50 rows and cancelling")
                self.window.shrink(to: 50)
                self.fetchTask?.cancel()
            }
        }
    }

    private func apply(element: StreamElement) {
        switch element {
        case .columns(let cols):
            columns = cols
        case .row(let row):
            window.append(row)
        case .rowsAffected(let count):
            rowsAffected = count
        case .statusMessage(let message):
            statusMessage = message
        case .truncated(let reason):
            phase = .truncated(reason: reason)
        }
    }

    private func classify(error: Error) -> AppError {
        let context = ErrorContext(operation: "loadPage")
        return ErrorClassifier.classify(error, context: context)
    }
}
