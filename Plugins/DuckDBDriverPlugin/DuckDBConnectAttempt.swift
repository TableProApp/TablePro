//
//  DuckDBConnectAttempt.swift
//  DuckDBDriverPlugin
//

import Foundation

internal enum DuckDBConnectAttemptError: Error, Equatable, Sendable {
    case timedOut
}

internal final class DuckDBConnectAttempt: @unchecked Sendable {
    internal static let defaultTimeoutMilliseconds = 30_000

    private enum State: Equatable {
        case connecting
        case timedOut
        case cancelled
        case finished
    }

    internal let deadline: ContinuousClock.Instant

    private let interrupt: @Sendable () -> Void
    private let lock = NSLock()
    private var state = State.connecting

    internal init(
        additionalFields: [String: String],
        now: ContinuousClock.Instant = .now,
        interrupt: @escaping @Sendable () -> Void
    ) {
        let timeoutMilliseconds = PluginConnectTimeout.milliseconds(
            in: additionalFields,
            default: Self.defaultTimeoutMilliseconds
        )
        self.deadline = now.advanced(by: .milliseconds(timeoutMilliseconds))
        self.interrupt = interrupt
    }

    internal func remainingMilliseconds(at now: ContinuousClock.Instant = .now) -> Int? {
        guard now < deadline else { return nil }
        let components = now.duration(to: deadline).components
        let milliseconds = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        return max(1, Int(milliseconds.rounded(.up)))
    }

    internal func check(at now: ContinuousClock.Instant = .now) throws {
        let resolution = lock.withLock { () -> (failure: State?, shouldInterrupt: Bool) in
            switch state {
            case .connecting where now >= deadline:
                state = .timedOut
                return (.timedOut, true)
            case .connecting, .finished:
                return (nil, false)
            case .timedOut:
                return (.timedOut, false)
            case .cancelled:
                return (.cancelled, false)
            }
        }
        if resolution.shouldInterrupt {
            interrupt()
        }
        try throwFailure(resolution.failure)
    }

    internal func expire(at now: ContinuousClock.Instant = .now) {
        let shouldInterrupt = lock.withLock {
            guard state == .connecting, now >= deadline else { return false }
            state = .timedOut
            return true
        }
        if shouldInterrupt {
            interrupt()
        }
    }

    internal func cancel() {
        let shouldInterrupt = lock.withLock {
            guard state == .connecting else { return false }
            state = .cancelled
            return true
        }
        if shouldInterrupt {
            interrupt()
        }
    }

    internal func finish(
        at now: ContinuousClock.Instant = .now,
        adopting result: () -> Void
    ) throws {
        let resolution = lock.withLock { () -> (failure: State?, shouldInterrupt: Bool, shouldAdopt: Bool) in
            switch state {
            case .connecting where now >= deadline:
                state = .timedOut
                return (.timedOut, true, false)
            case .connecting:
                state = .finished
                return (nil, false, true)
            case .timedOut:
                return (.timedOut, false, false)
            case .cancelled:
                return (.cancelled, false, false)
            case .finished:
                return (nil, false, false)
            }
        }
        if resolution.shouldInterrupt {
            interrupt()
        }
        try throwFailure(resolution.failure)
        if resolution.shouldAdopt {
            result()
        }
    }

    internal func stop() -> Error? {
        let failure = lock.withLock { () -> State? in
            switch state {
            case .connecting:
                state = .finished
                return nil
            case .timedOut:
                return .timedOut
            case .cancelled:
                return .cancelled
            case .finished:
                return nil
            }
        }
        switch failure {
        case .timedOut:
            return DuckDBConnectAttemptError.timedOut
        case .cancelled:
            return CancellationError()
        case nil, .connecting, .finished:
            return nil
        }
    }

    private func throwFailure(_ failure: State?) throws {
        switch failure {
        case .timedOut:
            throw DuckDBConnectAttemptError.timedOut
        case .cancelled:
            throw CancellationError()
        case nil, .connecting, .finished:
            return
        }
    }
}
