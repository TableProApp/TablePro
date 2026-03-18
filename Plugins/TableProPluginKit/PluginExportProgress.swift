//
//  PluginExportProgress.swift
//  TableProPluginKit
//

import Foundation

public final class PluginExportProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _currentTable: String = ""
    private var _currentTableIndex: Int = 0
    private var _processedRows: Int = 0
    private var _totalRows: Int = 0
    private var _statusMessage: String = ""
    private var _isCancelled: Bool = false

    private let updateInterval: Int = 1_000
    private var internalRowCount: Int = 0

    public var onUpdate: (@Sendable (String, Int, Int, Int, String) -> Void)?

    public init() {}

    public func setCurrentTable(_ name: String, index: Int) {
        lock.lock()
        _currentTable = name
        _currentTableIndex = index
        lock.unlock()
        notifyUpdate()
    }

    public func incrementRow() {
        lock.lock()
        internalRowCount += 1
        _processedRows = internalRowCount
        let shouldNotify = internalRowCount % updateInterval == 0
        lock.unlock()
        if shouldNotify {
            notifyUpdate()
        }
    }

    public func finalizeTable() {
        notifyUpdate()
    }

    public func setTotalRows(_ count: Int) {
        lock.lock()
        _totalRows = count
        lock.unlock()
    }

    public func setStatus(_ message: String) {
        lock.lock()
        _statusMessage = message
        lock.unlock()
        notifyUpdate()
    }

    public func checkCancellation() throws {
        lock.lock()
        let cancelled = _isCancelled
        lock.unlock()
        if cancelled || Task.isCancelled {
            throw PluginExportCancellationError()
        }
    }

    public func cancel() {
        lock.lock()
        _isCancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled
    }

    public var processedRows: Int {
        lock.lock()
        defer { lock.unlock() }
        return _processedRows
    }

    public var totalRows: Int {
        lock.lock()
        defer { lock.unlock() }
        return _totalRows
    }

    private func notifyUpdate() {
        lock.lock()
        let table = _currentTable
        let index = _currentTableIndex
        let rows = _processedRows
        let total = _totalRows
        let status = _statusMessage
        lock.unlock()
        onUpdate?(table, index, rows, total, status)
    }
}
