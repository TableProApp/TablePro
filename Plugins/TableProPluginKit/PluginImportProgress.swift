import Foundation

public final class PluginImportProgress: @unchecked Sendable {
    private let progress: Progress
    private let updateInterval: Int = 500
    private var internalCount: Int = 0
    private let lock = NSLock()

    public init(progress: Progress) {
        self.progress = progress
    }

    public func setEstimatedTotal(_ count: Int) {
        progress.totalUnitCount = Int64(count)
    }

    public func incrementStatement() {
        lock.lock()
        internalCount += 1
        let count = internalCount
        let shouldNotify = count % updateInterval == 0
        lock.unlock()
        if shouldNotify {
            progress.completedUnitCount = Int64(count)
        }
    }

    public func setStatus(_ message: String) {
        progress.localizedAdditionalDescription = message
    }

    public func checkCancellation() throws {
        if progress.isCancelled || Task.isCancelled {
            throw PluginImportCancellationError()
        }
    }

    public func cancel() {
        progress.cancel()
    }

    public var isCancelled: Bool {
        progress.isCancelled || Task.isCancelled
    }

    public var processedStatements: Int {
        lock.lock()
        defer { lock.unlock() }
        return internalCount
    }

    public var estimatedTotalStatements: Int {
        Int(progress.totalUnitCount)
    }

    public func finalize() {
        lock.lock()
        let count = internalCount
        lock.unlock()
        progress.completedUnitCount = Int64(count)
    }
}
