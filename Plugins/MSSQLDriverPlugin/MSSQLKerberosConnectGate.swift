import Darwin
import Foundation

final class AsyncLock: @unchecked Sendable {
    private let stateLock = NSLock()
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if tryAcquireImmediately() { return }
        await withCheckedContinuation { continuation in
            enqueueOrResume(continuation)
        }
    }

    func release() {
        stateLock.lock()
        if waiters.isEmpty {
            isLocked = false
            stateLock.unlock()
        } else {
            let next = waiters.removeFirst()
            stateLock.unlock()
            next.resume()
        }
    }

    private func tryAcquireImmediately() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        if !isLocked {
            isLocked = true
            return true
        }
        return false
    }

    private func enqueueOrResume(_ continuation: CheckedContinuation<Void, Never>) {
        stateLock.lock()
        if !isLocked {
            isLocked = true
            stateLock.unlock()
            continuation.resume()
        } else {
            waiters.append(continuation)
            stateLock.unlock()
        }
    }
}

final class MSSQLKerberosConnectGate: @unchecked Sendable {
    static let shared = MSSQLKerberosConnectGate()

    private let lock = AsyncLock()

    func connect(_ conn: FreeTDSConnection, principal: String, password: String) async throws {
        await lock.acquire()
        defer { lock.release() }

        guard !principal.isEmpty, !password.isEmpty else {
            try await conn.connect()
            return
        }

        let cache = try MSSQLKerberosCredentials.acquireTicket(principal: principal, password: password)
        defer { cache.destroy() }

        let previous = getenv("KRB5CCNAME").map { String(cString: $0) }
        setenv("KRB5CCNAME", cache.name, 1)
        defer {
            if let previous {
                setenv("KRB5CCNAME", previous, 1)
            } else {
                unsetenv("KRB5CCNAME")
            }
        }

        try await conn.connect()
    }
}
