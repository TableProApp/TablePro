import Foundation

nonisolated struct TransferProgress: Sendable, Equatable {
    nonisolated enum Stage: Sendable, Equatable {
        case preparing
        case counting
        case running
        case finishing
    }

    nonisolated enum Unit: Sendable, Equatable {
        case rows
        case statements
    }

    var stage: Stage
    var unit: Unit
    var completedUnits: Int = 0
    var totalUnits: Int?
    var objectName: String?
    var objectIndex: Int = 0
    var objectCount: Int = 0
    var status: String?
    var bytesRead: Int64?
    var totalBytes: Int64?

    init(stage: Stage, unit: Unit = .rows) {
        self.stage = stage
        self.unit = unit
    }

    // A total the work ran past is a guess, so it is never shown past the end.
    var fractionCompleted: Double? {
        if let totalUnits, totalUnits > 0 {
            return min(1, Double(completedUnits) / Double(totalUnits))
        }
        if let bytesRead, let totalBytes, totalBytes > 0 {
            return min(1, Double(bytesRead) / Double(totalBytes))
        }
        return nil
    }
}

// Reads a plugin's `Progress` on a timer: its own KVO fires every thousand rows and on threads the caller does not own.
nonisolated final class TransferProgressPoller: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var last: TransferProgress?
    private var isStopped = false

    static let interval: Duration = .milliseconds(250)

    func start(
        read: @escaping @Sendable () -> TransferProgress,
        report: @escaping @Sendable (TransferProgress) -> Void
    ) {
        let poll = Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.emit(read(), final: false, to: report)
                try? await Task.sleep(for: Self.interval)
            }
        }
        lock.withLock { task = poll }
    }

    // Nothing the timer read before the stop is reported after the final value.
    func stop(final progress: TransferProgress?, report: @Sendable (TransferProgress) -> Void) {
        let running = lock.withLock { () -> Task<Void, Never>? in
            isStopped = true
            defer { task = nil }
            return task
        }
        running?.cancel()
        if let progress { emit(progress, final: true, to: report) }
    }

    private func emit(_ progress: TransferProgress, final: Bool, to report: @Sendable (TransferProgress) -> Void) {
        let changed = lock.withLock { () -> Bool in
            guard final || !isStopped, last != progress else { return false }
            last = progress
            return true
        }
        if changed { report(progress) }
    }
}

// Foundation's `Progress` is thread-safe; the box lets a poller read it from its own task.
nonisolated final class SharedProgress: @unchecked Sendable {
    let progress: Progress

    init(_ progress: Progress) {
        self.progress = progress
    }

    var description: String? {
        progress.localizedDescription.flatMap { $0.isEmpty ? nil : $0 }
    }

    var status: String? {
        progress.localizedAdditionalDescription.flatMap { $0.isEmpty ? nil : $0 }
    }
}
