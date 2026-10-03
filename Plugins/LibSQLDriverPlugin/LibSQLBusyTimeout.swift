import CSQLite
import Foundation

/// Keeps a local libSQL statement waiting for a SQLite lock until its configured timeout or an
/// explicit cancellation. SQLite's built-in `sqlite3_busy_timeout` treats zero as "do not wait",
/// while TablePro's query-timeout policy uses zero for no limit.
final class LibSQLBusyTimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    private var timeoutMilliseconds: Int32 = 0
    private var retried = false

    static let retryIntervalMilliseconds: Int32 = 10

    func setTimeout(milliseconds: Int32) {
        lock.withLock { timeoutMilliseconds = milliseconds }
    }

    func beginOperation() {
        lock.withLock {
            isCancelled = false
            retried = false
        }
    }

    func cancel() {
        lock.withLock { isCancelled = true }
    }

    var hasRetried: Bool {
        lock.withLock { retried }
    }

    var cancellationRequested: Bool {
        lock.withLock { isCancelled }
    }

    func shouldRetry(afterRetryCount retryCount: Int32) -> Bool {
        lock.withLock {
            retried = true
            guard !isCancelled else { return false }
            guard timeoutMilliseconds > 0 else { return true }
            return Int64(retryCount) * Int64(Self.retryIntervalMilliseconds) < Int64(timeoutMilliseconds)
        }
    }
}

let libSQLBusyTimeoutHandler: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32 = { context, retryCount in
    guard let context else { return 0 }
    let state = Unmanaged<LibSQLBusyTimeoutState>.fromOpaque(context).takeUnretainedValue()
    guard state.shouldRetry(afterRetryCount: retryCount) else { return 0 }
    usleep(UInt32(LibSQLBusyTimeoutState.retryIntervalMilliseconds) * 1_000)
    return 1
}
