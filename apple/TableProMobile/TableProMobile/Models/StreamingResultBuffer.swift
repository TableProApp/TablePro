import Foundation
import TableProModels

@MainActor
@Observable
final class StreamingResultBuffer {
    private(set) var columns: [ColumnInfo] = []
    // The one copy of the rows: a list derives each row's display text when it draws it.
    private(set) var window: RowWindow
    private(set) var rowsAffected: Int?
    private(set) var statusMessage: String?
    private(set) var truncation: TruncationReason?

    @ObservationIgnored private var pendingRows: [Row] = []
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    private static let flushBatchSize = 200
    private static let flushInterval: Duration = .milliseconds(50)

    init(capacity: Int) {
        self.window = RowWindow(capacity: capacity)
    }

    var count: Int { window.count }
    var isEmpty: Bool { window.isEmpty }

    func apply(_ element: StreamElement) {
        switch element {
        case .columns(let cols):
            columns = cols
        case .row(let row):
            pendingRows.append(row)
            scheduleFlush()
        case .rowsAffected(let count):
            flush()
            rowsAffected = count
        case .statusMessage(let message):
            flush()
            statusMessage = message
        case .truncated(let reason):
            flush()
            truncation = reason
        }
    }

    func markTruncated(_ reason: TruncationReason) {
        truncation = reason
    }

    func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard !pendingRows.isEmpty else { return }
        window.append(contentsOf: pendingRows)
        pendingRows.removeAll(keepingCapacity: true)
    }

    func cancelFlush() {
        flushTask?.cancel()
        flushTask = nil
    }

    func shrink(to maxCount: Int) {
        window.shrink(to: maxCount)
    }

    func reset() {
        flushTask?.cancel()
        flushTask = nil
        columns = []
        window.clear()
        rowsAffected = nil
        statusMessage = nil
        truncation = nil
        pendingRows.removeAll(keepingCapacity: true)
    }

    private func scheduleFlush() {
        if pendingRows.count >= Self.flushBatchSize {
            flush()
            return
        }
        if flushTask == nil {
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: Self.flushInterval)
                guard !Task.isCancelled else { return }
                self?.flush()
            }
        }
    }
}
