//
//  PluginImportProgress.swift
//  TableProPluginKit
//

import Foundation

public final class PluginImportProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _processedStatements: Int = 0
    private var _estimatedTotalStatements: Int = 0
    private var _statusMessage: String = ""
    private var _isCancelled: Bool = false

    private let updateInterval: Int = 500
    private var internalCount: Int = 0

    public var onUpdate: (@Sendable (Int, Int, String) -> Void)?

    public init() {}

    public func setEstimatedTotal(_ count: Int) {
        lock.lock()
        _estimatedTotalStatements = count
        lock.unlock()
    }

    public func incrementStatement() {
        lock.lock()
        internalCount += 1
        _processedStatements = internalCount
        let shouldNotify = internalCount % updateInterval == 0
        lock.unlock()
        if shouldNotify {
            notifyUpdate()
        }
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
            throw PluginImportCancellationError()
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

    public var processedStatements: Int {
        lock.lock()
        defer { lock.unlock() }
        return _processedStatements
    }

    public var estimatedTotalStatements: Int {
        lock.lock()
        defer { lock.unlock() }
        return _estimatedTotalStatements
    }

    public func finalize() {
        notifyUpdate()
    }

    private func notifyUpdate() {
        lock.lock()
        let processed = _processedStatements
        let total = _estimatedTotalStatements
        let status = _statusMessage
        lock.unlock()
        onUpdate?(processed, total, status)
    }
}
