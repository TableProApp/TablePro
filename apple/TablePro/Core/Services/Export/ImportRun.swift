//
//  ImportRun.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal enum ImportStopChoice: Equatable, Sendable {
    case rollBack
    case commit
}

internal enum ImportCallKind: Equatable, Sendable {
    case data
    case begin
    case commit
    case rollback
    case session
}

internal enum ImportAdmission: Equatable, Sendable {
    case proceed
    case skip
}

internal enum ImportRunPhase: Equatable, Sendable {
    case running
    case pausing
    case paused(generation: Int)
    case stopping(ImportStopChoice)
    case finished
}

// One import run's gate and ledger. Every database call the run's sinks make passes `admit` and `release`, so
// once the gate is paused nothing is in flight and the ledger cannot change until the pause ends.
internal final class ImportRun: @unchecked Sendable {
    private let lock = NSLock()
    private var phase = ImportRunPhase.running
    private var inFlight = 0
    private var generation = 0
    private var chosenStop: ImportStopChoice?
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var ledger = ImportLedger()
    private var onChange: (@Sendable () -> Void)?
    private var interrupt: (@Sendable () -> Void)?

    internal var currentPhase: ImportRunPhase {
        lock.withLock { phase }
    }

    internal var stopChoice: ImportStopChoice? { lock.withLock { chosenStop } }

    internal var waitingCallCount: Int { lock.withLock { waiters.count } }

    internal func observe(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { onChange = handler }
    }

    internal var snapshot: ImportLedger {
        lock.withLock { ledger }
    }

    @discardableResult
    internal func record<T>(_ body: (inout ImportLedger) -> T) -> T {
        lock.withLock { body(&ledger) }
    }

    // Read under the same lock as the phase, so a question is never built from a pause that already ended.
    internal func questionIfPaused() -> (generation: Int, ledger: ImportLedger)? {
        lock.withLock {
            guard case .paused(let current) = phase else { return nil }
            return (current, ledger)
        }
    }

    internal func admit(_ kind: ImportCallKind) async throws -> ImportAdmission {
        while true {
            let cancelled = Task.isCancelled
            let (decision, wakes) = lock.withLock { decide(kind, taskCancelled: cancelled) }
            finishTransition(wakes)
            switch decision {
            case .proceed:
                return .proceed
            case .skip:
                return .skip
            case .refuse:
                throw PluginImportCancellationError()
            case .wait:
                await park()
            }
        }
    }

    internal func release() {
        let (changed, wakes) = lock.withLock { () -> (Bool, [CheckedContinuation<Void, Never>]) in
            inFlight = max(0, inFlight - 1)
            guard inFlight == 0 else { return (false, []) }
            if phase == .pausing {
                generation += 1
                phase = .paused(generation: generation)
                return (true, [])
            }
            if case .paused = phase { return (false, []) }
            return (false, takeWaiters())
        }
        wakes.forEach { $0.resume() }
        if changed { notify() }
    }

    // A COPY streams its whole block as one call, so a pause would wait for all of it. While one runs, Stop ends it
    // and the run, as any failure would: its rows cannot be resumed, and an owned transaction can only roll back.
    @discardableResult
    internal func requestPause() -> Bool {
        transition { phase in
            guard phase == .running else { return false }
            if interrupt != nil {
                phase = .stopping(.rollBack)
            } else if inFlight == 0 {
                generation += 1
                phase = .paused(generation: generation)
            } else {
                phase = .pausing
            }
            return true
        }
    }

    // `interrupt` ends the call early; it runs when the run stops while the call is in flight. A Stop that came after
    // the call was admitted stops it here, before it starts.
    internal func interruptible<T>(
        by interrupt: @escaping @Sendable () -> Void,
        _ body: () async throws -> T
    ) async throws -> T {
        let starts = lock.withLock { () -> Bool in
            guard phase == .running else { return false }
            self.interrupt = interrupt
            return true
        }
        guard starts else {
            stop(.rollBack)
            throw PluginImportCancellationError()
        }
        defer { lock.withLock { self.interrupt = nil } }
        return try await body()
    }

    // An answer to a question asked at `generation`: ignored once that pause has ended.
    @discardableResult
    internal func resume(generation asked: Int) -> Bool {
        transition { phase in
            guard phase == .paused(generation: asked) else { return false }
            phase = .running
            return true
        }
    }

    // A disappearing question must not admit a parked COMMIT before teardown cancels the task.
    @discardableResult
    internal func stopUnansweredPause() -> Bool {
        transition { phase in
            switch phase {
            case .pausing, .paused:
                phase = .stopping(.rollBack)
                return true
            case .running, .stopping, .finished:
                return false
            }
        }
    }

    @discardableResult
    internal func stop(_ choice: ImportStopChoice, generation asked: Int) -> Bool {
        transition { phase in
            guard phase == .paused(generation: asked) else { return false }
            phase = .stopping(choice)
            return true
        }
    }

    // Teardown and cancellation: no question, and it wins over any pause.
    @discardableResult
    internal func stop(_ choice: ImportStopChoice) -> Bool {
        transition { phase in
            switch phase {
            case .stopping, .finished:
                return false
            case .running, .pausing, .paused:
                phase = .stopping(choice)
                return true
            }
        }
    }

    @discardableResult
    internal func finish() -> Bool {
        transition { phase in
            guard inFlight == 0 else { return false }
            switch phase {
            case .running, .stopping:
                phase = .finished
                return true
            case .pausing, .paused, .finished:
                return false
            }
        }
    }

    internal func complete() async {
        if Task.isCancelled { stop(.rollBack) }
        while currentPhase != .finished {
            if finish() { return }
            await park(untilIdle: true)
        }
    }

    // MARK: - Private

    private enum Decision {
        case proceed
        case skip
        case refuse
        case wait
    }

    private func decide(_ kind: ImportCallKind, taskCancelled: Bool) -> (Decision, [CheckedContinuation<Void, Never>]?) {
        var wakes: [CheckedContinuation<Void, Never>]?
        if taskCancelled, latchesStop {
            phase = .stopping(.rollBack)
            chosenStop = .rollBack
            wakes = takeWaiters()
        }
        let decision: Decision
        switch phase {
        case .running:
            decision = .proceed
        case .finished:
            decision = .refuse
        case .pausing, .paused:
            decision = .wait
        case .stopping(let choice):
            decision = Self.admission(of: kind, under: choice)
        }
        if decision == .proceed { inFlight += 1 }
        return (decision, wakes)
    }

    private var latchesStop: Bool {
        switch phase {
        case .running, .pausing, .paused: return true
        case .stopping, .finished: return false
        }
    }

    private static func admission(of kind: ImportCallKind, under choice: ImportStopChoice) -> Decision {
        switch (kind, choice) {
        case (.data, _), (.begin, _), (.commit, .rollBack):
            return .refuse
        case (.commit, .commit), (.rollback, .rollBack), (.session, _):
            return .proceed
        case (.rollback, .commit):
            return .skip
        }
    }

    // Registers under the lock after reading the phase again, so a stop or resume that ran first is never missed.
    private func park(untilIdle: Bool = false) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let parked = lock.withLock { () -> Bool in
                    switch phase {
                    case .pausing, .paused:
                        waiters[id] = continuation
                        return true
                    case .running, .stopping:
                        if untilIdle, inFlight > 0 {
                            waiters[id] = continuation
                            return true
                        }
                        return false
                    case .finished:
                        return false
                    }
                }
                if !parked { continuation.resume() }
            }
        } onCancel: {
            stop(.rollBack)
        }
    }

    private func takeWaiters() -> [CheckedContinuation<Void, Never>] {
        let pending = Array(waiters.values)
        waiters.removeAll()
        return pending
    }

    @discardableResult
    private func transition(_ change: (inout ImportRunPhase) -> Bool) -> Bool {
        let wakes = lock.withLock { () -> [CheckedContinuation<Void, Never>]? in
            guard change(&phase) else { return nil }
            if case .stopping(let choice) = phase {
                chosenStop = choice
                // Under the lock: the interrupted call cannot return and let the next statement start meanwhile.
                interrupt?()
            }
            switch phase {
            case .pausing, .paused:
                return []
            case .running, .stopping, .finished:
                return takeWaiters()
            }
        }
        guard let wakes else { return false }
        wakes.forEach { $0.resume() }
        notify()
        return true
    }

    private func finishTransition(_ wakes: [CheckedContinuation<Void, Never>]?) {
        guard let wakes else { return }
        wakes.forEach { $0.resume() }
        notify()
    }

    private func notify() {
        let handler = lock.withLock { onChange }
        handler?()
    }
}
