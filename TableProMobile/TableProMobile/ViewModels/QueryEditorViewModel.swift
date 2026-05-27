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
    static let maxBufferedRows = 10_000
    private static let memorySafetyMarginBytes = 64 * 1_024 * 1_024
    private static let budgetCheckInterval = 500

    private let buffer: StreamingResultBuffer
    private(set) var phase: Phase = .idle
    private(set) var executionTime: TimeInterval = 0

    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var startedAt: Date?

    init(windowCapacity: Int = QueryEditorViewModel.maxBufferedRows) {
        self.buffer = StreamingResultBuffer(capacity: windowCapacity)
    }

    var columns: [ColumnInfo] { buffer.columns }
    var window: RowWindow { buffer.window }
    var legacyRows: [[String?]] { buffer.legacyRows }
    var rowsAffected: Int? { buffer.rowsAffected }
    var statusMessage: String? { buffer.statusMessage }
    var truncationReason: TruncationReason? { buffer.truncation }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var truncationMessage: String? {
        guard let truncationReason else { return nil }
        let shown = buffer.legacyRows.count
        switch truncationReason {
        case .rowCap:
            return String(format: String(localized: "Showing the first %d rows. Add LIMIT to fetch more."), shown)
        case .memoryPressure:
            return String(format: String(localized: "Stopped at %d rows to stay within memory limits. Add LIMIT to fetch fewer."), shown)
        case .cancelled:
            return String(format: String(localized: "Stopped. Showing %d rows."), shown)
        case .driverLimit:
            return String(format: String(localized: "The database limited the result. Showing %d rows."), shown)
        }
    }

    func run(driver: DatabaseDriver, query: String, maxRows: Int = QueryEditorViewModel.maxBufferedRows) async {
        fetchTask?.cancel()
        let options = StreamOptions(
            textTruncationBytes: 4_096,
            inlineBinary: false,
            maxRows: maxRows,
            lazyContext: nil
        )
        phase = .running
        buffer.reset()
        executionTime = 0
        startedAt = Date()

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                var sinceBudgetCheck = 0
                for try await element in driver.executeStreaming(query: query, options: options) {
                    if Task.isCancelled { break }
                    self.buffer.apply(element)
                    guard case .row = element else { continue }
                    sinceBudgetCheck += 1
                    if sinceBudgetCheck >= Self.budgetCheckInterval {
                        sinceBudgetCheck = 0
                        if self.isMemoryConstrained() {
                            self.buffer.markTruncated(.memoryPressure)
                            break
                        }
                    }
                }
                self.buffer.flush()
                self.finalizeTiming()
                self.resolvePhase()
            } catch is CancellationError {
                self.buffer.flush()
                self.finalizeTiming()
                self.phase = .truncated(reason: self.buffer.truncation ?? .cancelled)
            } catch {
                self.buffer.flush()
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
        buffer.reset()
        executionTime = 0
        phase = .idle
    }

    nonisolated func handlePressure(_ level: MemoryPressureMonitor.Level) async {
        await MainActor.run {
            switch level {
            case .normal:
                return
            case .warning, .critical:
                guard case .running = self.phase else { return }
                Self.logger.warning("Memory pressure: stopping query stream to stay within limits")
                self.fetchTask?.cancel()
                guard !self.buffer.isEmpty else { return }
                self.buffer.markTruncated(.memoryPressure)
                self.phase = .truncated(reason: .memoryPressure)
            }
        }
    }

    private func isMemoryConstrained() -> Bool {
        !MemoryPressureMonitor.shared.hasHeadroom(forBytes: Self.memorySafetyMarginBytes)
    }

    private func resolvePhase() {
        if let reason = buffer.truncation {
            phase = .truncated(reason: reason)
        } else if case .running = phase {
            phase = .finished
        }
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
