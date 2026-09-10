//
//  ObjectCopyProgress.swift
//  TablePro
//
//  The run's progress, reachable from the copy loop.
//
//  A `Progress` is not `Sendable`, and the loop runs inside the scoped-driver
//  closure rather than on the main actor, so it crosses in a lock-guarded box.
//  That is the shape `PluginExportProgress` already uses for the same reason.
//

import Foundation

internal final class ObjectCopyProgress: @unchecked Sendable {
    private let progress: Progress
    private let lock = NSLock()
    private var rows: Int = 0
    private var object: String = ""

    internal init(progress: Progress) {
        self.progress = progress
    }

    internal var isCancelled: Bool { progress.isCancelled }

    internal var rowsCopied: Int {
        lock.lock()
        defer { lock.unlock() }
        return rows
    }

    internal var currentObject: String {
        lock.lock()
        defer { lock.unlock() }
        return object
    }

    internal func startObject(_ name: String) {
        lock.lock()
        object = name
        lock.unlock()
        progress.localizedDescription = name
    }

    /// `count` is the running total for the object being copied, not an increment, because the
    /// copier already counts its own rows and a second counter would drift from it.
    internal func setRowsForCurrentObject(_ count: Int, completedBefore: Int) {
        lock.lock()
        rows = completedBefore + count
        let total = rows
        lock.unlock()
        progress.completedUnitCount = Int64(total)
    }

    internal func setTotalRows(_ total: Int) {
        progress.totalUnitCount = Int64(max(total, 0))
    }
}
