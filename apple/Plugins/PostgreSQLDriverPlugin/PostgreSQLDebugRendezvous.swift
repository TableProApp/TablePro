//
//  PostgreSQLDebugRendezvous.swift
//  PostgreSQLDriverPlugin
//

import Foundation

// Where the target's notice receiver hands over the port it waits on, and where a stop learns the target's
// call is over. `abandon()` releases the waiters when the target could not be ended in time.
final class PostgreSQLDebugRendezvous: @unchecked Sendable {
    private let lock = NSLock()
    private var deliveredPort: Int?
    private var isSettled = false
    private var abandoned = false
    private var portWaiters: [CheckedContinuation<Int?, Never>] = []
    private var settleWaiters: [CheckedContinuation<Void, Never>] = []

    var hasPort: Bool {
        lock.withLock { deliveredPort != nil }
    }

    var hasSettled: Bool {
        lock.withLock { isSettled }
    }

    // True when the waiters were released without the target's call ending: it may still hold its locks.
    var isAbandoned: Bool {
        lock.withLock { abandoned }
    }

    func abandon() {
        release(abandoning: true)
    }

    func deliver(port: Int) {
        let waiters = lock.withLock { () -> [CheckedContinuation<Int?, Never>] in
            deliveredPort = port
            defer { portWaiters.removeAll() }
            return portWaiters
        }
        waiters.forEach { $0.resume(returning: port) }
    }

    func settle() {
        release(abandoning: false)
    }

    private func release(abandoning: Bool) {
        let released = lock.withLock {
            () -> (Int?, [CheckedContinuation<Int?, Never>], [CheckedContinuation<Void, Never>])? in
            guard !isSettled else { return nil }
            isSettled = true
            abandoned = abandoning
            defer {
                portWaiters.removeAll()
                settleWaiters.removeAll()
            }
            return (deliveredPort, portWaiters, settleWaiters)
        }
        guard let released else { return }
        released.1.forEach { $0.resume(returning: released.0) }
        released.2.forEach { $0.resume() }
    }

    // The port once the target reaches the routine, or nil when its call ended first.
    func port() async -> Int? {
        await withCheckedContinuation { continuation in
            let ready: Int?? = lock.withLock {
                if let deliveredPort { return .some(deliveredPort) }
                if isSettled { return .some(nil) }
                portWaiters.append(continuation)
                return .none
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    func settled() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = lock.withLock {
                if isSettled { return true }
                settleWaiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
}
