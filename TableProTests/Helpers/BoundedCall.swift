//
//  BoundedCall.swift
//  TableProTests
//

import Foundation

internal enum BoundedCall {
    private final class FirstArrival<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value?, Never>?

        init(_ continuation: CheckedContinuation<Value?, Never>) {
            self.continuation = continuation
        }

        func claim() -> CheckedContinuation<Value?, Never>? {
            lock.withLock {
                defer { continuation = nil }
                return continuation
            }
        }
    }

    static let deadline = Duration.seconds(10)

    static func result<Value: Sendable>(
        onDeadline: @escaping @Sendable () -> Void = {},
        of work: @escaping @Sendable () async -> Value
    ) async -> Value? {
        await withCheckedContinuation { continuation in
            let arrival = FirstArrival(continuation)
            let timer = Task {
                try? await Task.sleep(for: deadline)
                guard let pending = arrival.claim() else { return }
                onDeadline()
                pending.resume(returning: nil)
            }
            Task {
                let value = await work()
                arrival.claim()?.resume(returning: value)
                timer.cancel()
            }
        }
    }

    static func resultOnItsOwnThread<Value: Sendable>(
        onDeadline: @escaping @Sendable () -> Void = {},
        of work: @escaping @Sendable () -> Value
    ) async -> Value? {
        await result(onDeadline: onDeadline) {
            await withCheckedContinuation { continuation in
                Thread.detachNewThread { continuation.resume(returning: work()) }
            }
        }
    }
}
