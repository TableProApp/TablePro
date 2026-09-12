import Foundation

public final class PluginExportProgress: @unchecked Sendable {
    private let progress: Progress
    private let updateInterval: Int = 1_000
    private var internalRowCount: Int = 0
    private var _currentTableIndex: Int = 0
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

    public func setCurrentTable(_ name: String, index: Int) {
        progress.localizedDescription = name
        lock.lock()
        _currentTableIndex = index
        lock.unlock()
    }

    public var currentTableIndex: Int {
        lock.lock()
        defer { lock.unlock() }
        return _currentTableIndex
    }

    public func incrementRow() {
        lock.lock()
        internalRowCount += 1
        let count = internalRowCount
        let shouldNotify = count % updateInterval == 0
        lock.unlock()
        if shouldNotify {
            progress.completedUnitCount = Int64(count)
        }
    }

    public func finalizeTable() {
        lock.lock()
        let count = internalRowCount
        lock.unlock()
        progress.completedUnitCount = Int64(count)
    }

    public func setStatus(_ message: String) {
        progress.localizedAdditionalDescription = message
    }

    public func checkCancellation() throws {
        if progress.isCancelled || Task.isCancelled {
            throw PluginExportCancellationError()
        }
    }

    public func cancel() {
        progress.cancel()
    }

    public var isCancelled: Bool {
        progress.isCancelled || Task.isCancelled
    }

    public var processedRows: Int {
        lock.lock()
        defer { lock.unlock() }
        return internalRowCount
    }

    public var totalRows: Int {
        Int(progress.totalUnitCount)
    }

}
