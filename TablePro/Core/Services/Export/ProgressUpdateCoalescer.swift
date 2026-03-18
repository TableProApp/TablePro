//
//  ProgressUpdateCoalescer.swift
//  TablePro
//

import Foundation

/// Ensures only one `Task { @MainActor }` is in-flight at a time to prevent
/// flooding the main actor queue during high-throughput exports/imports.
final class ProgressUpdateCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var isPending = false

    /// Returns `true` if the caller should dispatch a UI update (no update is in-flight).
    func markPending() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isPending { return false }
        isPending = true
        return true
    }

    func clearPending() {
        lock.lock()
        isPending = false
        lock.unlock()
    }
}
