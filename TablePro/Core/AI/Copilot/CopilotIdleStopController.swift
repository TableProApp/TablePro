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
    private let isAuthenticated: () -> Bool
    private let isRunning: () -> Bool
    private let onStopRequest: () async -> Void
    private var task: Task<Void, Never>?

    init(
        timeout: Duration,
        isAuthenticated: @escaping () -> Bool,
        isRunning: @escaping () -> Bool,
        onStopRequest: @escaping () async -> Void
    ) {
        self.timeout = timeout
        self.isAuthenticated = isAuthenticated
        self.isRunning = isRunning
        self.onStopRequest = onStopRequest
    }

    deinit {
        task?.cancel()
    }

    /// Cancel any prior schedule and start a new one. No-op when already authenticated.
    func schedule() {
        task?.cancel()
        guard !isAuthenticated() else {
            task = nil
            return
        }
        let timeout = self.timeout
        let isAuthenticated = self.isAuthenticated
        let isRunning = self.isRunning
        let onStopRequest = self.onStopRequest
        task = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard !isAuthenticated(), isRunning() else { return }
            await onStopRequest()
        }
    }

    /// Cancel any pending stop without triggering it.
    func cancel() {
        task?.cancel()
        task = nil
    }
}
