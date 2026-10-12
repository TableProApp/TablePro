import Foundation

public final class PluginImportProgress: @unchecked Sendable {
    private let progress: Progress
    private let updateInterval: Int = 500
    private var internalCount: Int = 0
    private let lock = NSLock()

    /// `localizedAdditionalDescription` is the channel `setStatus` writes, and Foundation fills it
    /// in when nobody has: measured, a `Progress` carrying a total reports "10 of 100" there and
    /// posts a KVO change for it on every `completedUnitCount` write. Seeding it empty takes the
    /// property over for good, so a host observing it hears the plugin and nothing else. The import
    /// sheet showed that raw row count in place of its statement count for exactly this reason.
    public init(progress: Progress) {
        self.progress = progress
        progress.localizedAdditionalDescription = ""
    }

    public func setEstimatedTotal(_ count: Int) {
        if progress.totalUnitCount <= 0 {
            progress.totalUnitCount = Int64(count)
        }
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

    public func incrementStatement(by amount: Int) {
        guard amount > 0 else { return }
        lock.lock()
        let previous = internalCount
        internalCount += amount
        let count = internalCount
        lock.unlock()
        if count / updateInterval != previous / updateInterval {
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
