import Foundation
import os

internal final class SSHConnectionAttempt: @unchecked Sendable {
    private enum Outcome {
        case running
        case cancelled
        case timedOut(ConnectionTimeoutEndpoint)
        case finished
    }

    private struct Prompt {
        let id: UUID
        let dismiss: @MainActor @Sendable () -> Void
    }

    private struct TransportInterrupt {
        let id: UUID
        let action: @Sendable () -> Void
    }

    private struct State {
        var outcome = Outcome.running
        var endpoint: ConnectionTimeoutEndpoint
        var prompt: Prompt?
        var transportInterrupt: TransportInterrupt?
    }

    internal let deadline: ConnectionDeadline
    private let state: OSAllocatedUnfairLock<State>

    internal init(deadline: ConnectionDeadline, endpoint: ConnectionTimeoutEndpoint) {
        self.deadline = deadline
        self.state = OSAllocatedUnfairLock(initialState: State(endpoint: endpoint))
    }

    internal func startWatchdog() -> Task<Void, Never> {
        Task.detached { [weak self, deadline] in
            do {
                try await Task.sleep(for: deadline.remainingDuration)
            } catch {
                return
            }
            self?.expire()
        }
    }

    internal func prepare(for endpoint: ConnectionTimeoutEndpoint) throws {
        if Task.isCancelled {
            cancel()
        } else if deadline.isExpired {
            expire(at: endpoint)
        }

        let outcome = state.withLock { state -> Outcome in
            if case .running = state.outcome {
                state.endpoint = endpoint
            }
            return state.outcome
        }
        try throwIfStopped(outcome)
    }

    internal func check(for endpoint: ConnectionTimeoutEndpoint) throws {
        try prepare(for: endpoint)
    }

    internal func registerTransportInterrupt(_ interrupt: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        let shouldInterrupt = state.withLock { state -> Bool in
            guard case .running = state.outcome else { return true }
            state.transportInterrupt = TransportInterrupt(id: id, action: interrupt)
            return false
        }
        if shouldInterrupt {
            interrupt()
        }
        return id
    }

    internal func unregisterTransportInterrupt(_ id: UUID) {
        state.withLock { state in
            guard state.transportInterrupt?.id == id else { return }
            state.transportInterrupt = nil
        }
    }

    internal func clearTransportInterrupt() {
        state.withLock { $0.transportInterrupt = nil }
    }

    internal func registerPrompt(
        for endpoint: ConnectionTimeoutEndpoint,
        dismiss: @escaping @MainActor @Sendable () -> Void
    ) throws -> UUID {
        try prepare(for: endpoint)
        let id = UUID()
        let outcome = state.withLock { state -> Outcome in
            guard case .running = state.outcome else { return state.outcome }
            state.prompt = Prompt(id: id, dismiss: dismiss)
            return .running
        }
        do {
            try throwIfStopped(outcome)
            return id
        } catch {
            Task { @MainActor in dismiss() }
            throw error
        }
    }

    internal func unregisterPrompt(_ id: UUID) {
        state.withLock { state in
            guard state.prompt?.id == id else { return }
            state.prompt = nil
        }
    }

    internal func cancel() {
        stop(with: .cancelled)
    }

    internal func finish() {
        state.withLock { state in
            guard case .running = state.outcome else { return }
            state.outcome = .finished
            state.prompt = nil
            state.transportInterrupt = nil
        }
    }

    private func expire() {
        let endpoint = state.withLock { $0.endpoint }
        expire(at: endpoint)
    }

    private func expire(at endpoint: ConnectionTimeoutEndpoint) {
        stop(with: .timedOut(endpoint))
    }

    private func stop(with outcome: Outcome) {
        let actions = state.withLock { state -> (Prompt?, (@Sendable () -> Void)?) in
            guard case .running = state.outcome else { return (nil, nil) }
            state.outcome = outcome
            let actions = (state.prompt, state.transportInterrupt?.action)
            state.prompt = nil
            state.transportInterrupt = nil
            return actions
        }
        actions.1?()
        if let prompt = actions.0 {
            Task { @MainActor in prompt.dismiss() }
        }
    }

    private func throwIfStopped(_ outcome: Outcome) throws {
        switch outcome {
        case .running:
            return
        case .cancelled, .finished:
            throw CancellationError()
        case .timedOut(let endpoint):
            throw deadline.timeoutError(for: endpoint)
        }
    }
}

internal final class ConnectionRelayDeadlineProvider: @unchecked Sendable {
    internal struct Budget: Sendable {
        let deadline: ConnectionDeadline
        let isInitial: Bool
    }

    private let configuredSeconds: Int
    private let initialDeadline: OSAllocatedUnfairLock<ConnectionDeadline?>

    internal init(initialDeadline: ConnectionDeadline) {
        self.configuredSeconds = initialDeadline.configuredSeconds
        self.initialDeadline = OSAllocatedUnfairLock(initialState: initialDeadline)
    }

    internal func next(
        startedAt: ContinuousClock.Instant = .now
    ) -> Budget {
        initialDeadline.withLock { initialDeadline in
            if let deadline = initialDeadline {
                initialDeadline = nil
                return Budget(deadline: deadline, isInitial: true)
            }
            return Budget(
                deadline: ConnectionDeadline(
                    configuredSeconds: configuredSeconds,
                    startedAt: startedAt
                ),
                isInitial: false
            )
        }
    }
}
