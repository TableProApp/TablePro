//
//  CopilotIdleStopController.swift
//  TablePro
//
//  Schedules a deferred stop when an external condition (typically:
//  Copilot LSP server is running but the user hasn't signed in) holds
//  past a timeout. Pulled out of CopilotService so the timer logic
//  can be unit-tested without launching the real LSP process.
//

import Foundation

@MainActor
final class CopilotIdleStopController {
    private let timeout: Duration
    private let clock: any Clock<Duration>
    private let isAuthenticated: () -> Bool
    private let isRunning: () -> Bool
    private let onStopRequest: () async -> Void
    private var task: Task<Void, Never>?

    init(
        timeout: Duration,
        clock: any Clock<Duration> = ContinuousClock(),
        isAuthenticated: @escaping () -> Bool,
        isRunning: @escaping () -> Bool,
        onStopRequest: @escaping () async -> Void
    ) {
        self.timeout = timeout
        self.clock = clock
        self.isAuthenticated = isAuthenticated
        self.isRunning = isRunning
        self.onStopRequest = onStopRequest
    }

    deinit {
        task?.cancel()
    }

    @discardableResult
    func schedule() -> Task<Void, Never>? {
        task?.cancel()
        guard !isAuthenticated() else {
            task = nil
            return nil
        }
        let timeout = self.timeout
        let clock = self.clock
        let isAuthenticated = self.isAuthenticated
        let isRunning = self.isRunning
        let onStopRequest = self.onStopRequest
        let scheduled = Task {
            do {
                try await clock.sleep(for: timeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard !isAuthenticated(), isRunning() else { return }
            await onStopRequest()
        }
        task = scheduled
        return scheduled
    }

    /// Cancel any pending stop without triggering it.
    func cancel() {
        task?.cancel()
        task = nil
    }
}
