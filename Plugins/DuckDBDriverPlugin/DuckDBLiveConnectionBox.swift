//
//  DuckDBLiveConnectionBox.swift
//  DuckDBDriverPlugin
//

import CDuckDB
import Foundation

/// The live `duckdb_connection`, readable without awaiting the actor that owns it.
///
/// Two callers need it synchronously. `cancelQuery` cannot await the actor to ask for the pointer
/// before calling `duckdb_interrupt`, and the menu has to decide whether to offer Release File Lock
/// while building itself. The pointer used to be captured once at connect and never touched again,
/// which was correct only while the handle's lifetime matched the session's. Now that an idle
/// release closes and reopens it, a stale copy points at freed memory, and `duckdb_interrupt` on
/// one segfaults.
///
/// So the actor owns the writes and makes them either side of the C calls: cleared **before**
/// `duckdb_disconnect`, set **after** `duckdb_connect`. A cancel that lands in the gap reads nil
/// and does nothing, which is the right answer, because there is no query running to interrupt.
final class DuckDBLiveConnectionBox: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var handle: duckdb_connection?

    var current: duckdb_connection? {
        lock.lock()
        defer { lock.unlock() }
        return handle
    }

    /// Whether a handle is open right now. False both while the file's lock is released and after
    /// a disconnect, which is exactly when there is nothing to release.
    var isOpen: Bool { current != nil }

    func set(_ newHandle: duckdb_connection?) {
        lock.lock()
        handle = newHandle
        lock.unlock()
    }
}
