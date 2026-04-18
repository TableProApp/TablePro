import Foundation
import os

public final class PluginExportProgress: @unchecked Sendable {
    private let progress: Progress
    private let updateInterval: Int = 1_000
    private var internalRowCount: Int = 0
    private var _currentTableIndex: Int = 0
    private let lock = NSLock()
    private static let logger = Logger(subsystem: "com.TablePro", category: "ExportProgress")

    public init(progress: Progress) {
        self.progress = progress
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
            if count % 100_000 == 0 {
                Self.logger.debug("[export-progress] incrementRow milestone: \(count)")
            }
        }
    }

    public func finalizeTable() {
        lock.lock()
        let count = internalRowCount
        lock.unlock()
        Self.logger.info("[export-progress] finalizeTable: internalRowCount=\(count)")
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
