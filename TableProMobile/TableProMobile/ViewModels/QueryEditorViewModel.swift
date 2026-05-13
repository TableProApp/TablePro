import Foundation
import os
import TableProDatabase
import TableProModels

@MainActor
@Observable
final class QueryEditorViewModel {
    enum Phase: Sendable {
        case idle
        case running
        case finished
        case truncated(reason: TruncationReason)
        case error(AppError)
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "QueryEditorViewModel")

    private(set) var columns: [ColumnInfo] = []
    private(set) var window: RowWindow
    private(set) var legacyRows: [[String?]] = []
    private(set) var rowsReceived: Int = 0
    private(set) var phase: Phase = .idle
    private(set) var rowsAffected: Int?
    private(set) var statusMessage: String?
    private(set) var executionTime: TimeInterval = 0

    @ObservationIgnored private var pendingRows: [Row] = []
    @ObservationIgnored private var pendingRowsReceived: Int = 0
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var startedAt: Date?

    private static let flushBatchSize = 200
    private static let flushInterval: Duration = .milliseconds(50)

    init(windowCapacity: Int = 100_000) {
        self.window = RowWindow(capacity: windowCapacity)
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    func run(driver: DatabaseDriver, query: String, maxRows: Int = 100_000) async {
        fetchTask?.cancel()
        let options = StreamOptions(
            textTruncationBytes: 4_096,
            inlineBinary: false,
            maxRows: maxRows,
            lazyContext: nil
        )
        phase = .running
        columns = []
        window.clear()
        legacyRows.removeAll(keepingCapacity: true)
        rowsReceived = 0
        rowsAffected = nil
        statusMessage = nil
        executionTime = 0
        pendingRows.removeAll(keepingCapacity: true)
        pendingRowsReceived = 0
        startedAt = Date()

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await element in driver.executeStreaming(query: query, options: options) {
                    if Task.isCancelled { break }
                    self.apply(element: element)
                }
                self.flushPendingRows()
                self.finalizeTiming()
                if case .running = self.phase {
                    self.phase = .finished
                }
            } catch is CancellationError {
                self.flushPendingRows()
                self.finalizeTiming()
                self.phase = .truncated(reason: .cancelled)
            } catch {
                self.flushPendingRows()
                self.finalizeTiming()
                self.phase = .error(self.classify(error: error))
            }
        }
        fetchTask = task
        await task.value
    }

    func stop() {
        fetchTask?.cancel()
    }

    func reset() {
        fetchTask?.cancel()
        flushTask?.cancel()
        flushTask = nil
        columns = []
        window.clear()
        legacyRows.removeAll(keepingCapacity: true)
        rowsReceived = 0
        rowsAffected = nil
        statusMessage = nil
        executionTime = 0
        pendingRows.removeAll(keepingCapacity: true)
        pendingRowsReceived = 0
        phase = .idle
    }

    nonisolated func handlePressure(_ level: MemoryPressureMonitor.Level) async {
        await MainActor.run {
            switch level {
            case .normal:
                break
            case .warning:
                Self.logger.warning("Memory pressure warning: shrinking editor window to 100 rows")
                self.window.shrink(to: 100)
                self.shrinkLegacyRows(to: 100)
            case .critical:
                Self.logger.error("Memory pressure critical: cancelling editor stream and shrinking to 50 rows")
                self.window.shrink(to: 50)
                self.shrinkLegacyRows(to: 50)
                self.fetchTask?.cancel()
            }
        }
    }

    private func shrinkLegacyRows(to count: Int) {
        guard legacyRows.count > count else { return }
        legacyRows.removeFirst(legacyRows.count - count)
    }

    private func apply(element: StreamElement) {
        switch element {
        case .columns(let cols):
            columns = cols
        case .row(let row):
            pendingRows.append(row)
            pendingRowsReceived += 1
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
            let drop = legacyRows.count - window.count
            legacyRows.removeFirst(drop)
        }
        rowsReceived = pendingRowsReceived
        pendingRows.removeAll(keepingCapacity: true)
    }

    private func finalizeTiming() {
        if let startedAt {
            executionTime = Date().timeIntervalSince(startedAt)
        }
    }

    private func classify(error: Error) -> AppError {
        let context = ErrorContext(operation: "executeQuery")
        return ErrorClassifier.classify(error, context: context)
    }
}
