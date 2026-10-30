//
//  PostgreSQLDebugRendezvous.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import os

// Where the target's notice receiver hands over the port it waits on, and where a stop learns the target's
// call is over. `abandon()` releases the waiters when the target could not be ended in time.
final class PostgreSQLDebugRendezvous: @unchecked Sendable {
    private let lock = NSLock()
    private var deliveredPort: Int?
    private var isSettled = false
    private var abandoned = false
    private var portWaiters: [CheckedContinuation<Int?, Never>] = []
    private var settleWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var withdrawnWaiters: Set<Int> = []
    private var lastWaiter = 0

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

    var waiterCount: Int {
        lock.withLock { portWaiters.count + settleWaiters.count }
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
                withdrawnWaiters.removeAll()
            }
            return (deliveredPort, portWaiters, Array(settleWaiters.values))
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

    // Returns when this settles, or at once when the waiting task is cancelled, which withdraws the waiter.
    func settled() async {
        let waiter = lock.withLock { () -> Int in
            lastWaiter += 1
            return lastWaiter
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready = lock.withLock { () -> Bool in
                    if isSettled || withdrawnWaiters.remove(waiter) != nil { return true }
                    settleWaiters[waiter] = continuation
                    return false
                }
                if ready { continuation.resume() }
            }
        } onCancel: {
            let withdrawn = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                if let continuation = settleWaiters.removeValue(forKey: waiter) { return continuation }
                if !isSettled { withdrawnWaiters.insert(waiter) }
                return nil
            }
            withdrawn?.resume()
        }
    }

    // The step's result, or nil when this settles first. The losing wait on this is withdrawn before the answer is
    // given, so nothing waits on it past the call; only a step still running on its connection outlives a nil answer.
    func reply<T: Sendable>(to step: Task<T, Error>) async -> Result<T, Error>? {
        let claimed = OSAllocatedUnfairLock(initialState: false)
        let claim = { @Sendable () -> Bool in
            claimed.withLock { done -> Bool in
                defer { done = true }
                return !done
            }
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, Error>?, Never>) in
            let signal = Task {
                await self.settled()
                if claim() { continuation.resume(returning: nil) }
            }
            Task {
                let result = await step.result
                guard claim() else { return }
                signal.cancel()
                continuation.resume(returning: result)
            }
        }
    }
}
