//
//  ConnectionHealthMonitor.swift
//  TablePro
//
//  Actor that monitors database connection health with periodic pings
//  and automatic reconnection with exponential backoff.
//

import Foundation
import os

// MARK: - Health State

extension ConnectionHealthMonitor {
    /// Represents the current health state of a monitored connection.
    enum HealthState: Sendable, Equatable {
        case healthy
        case checking
        case reconnecting(attempt: Int) // 1-based attempt number
        case failed
    }
}

// MARK: - ConnectionHealthMonitor

/// Monitors a single database connection's health via periodic pings and
/// automatically attempts reconnection with exponential backoff on failure.
///
/// Uses closure-based dependency injection so it does not directly reference
/// `DatabaseDriver` (which is not `Sendable`). The caller provides `pingHandler`
/// and `reconnectHandler` closures.
actor ConnectionHealthMonitor {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionHealthMonitor")

    // MARK: - Configuration

    private static let pingInterval: TimeInterval = 30.0
    private static let initialBackoffDelays: [TimeInterval] = [2.0, 4.0, 8.0]
    private static let maxBackoffDelay: TimeInterval = 120.0

    // MARK: - Dependencies

    private let connectionId: UUID
    private let pingHandler: @Sendable () async -> Bool
    private let reconnectHandler: @Sendable () async -> Bool
    private let onStateChanged: @Sendable (UUID, HealthState) async -> Void

    // MARK: - State

    private var state: HealthState = .healthy
    private var monitoringTask: Task<Void, Never>?
    private var wakeUpContinuation: AsyncStream<Void>.Continuation?

    // MARK: - Initialization

    /// Creates a new health monitor for a database connection.
    ///
    /// - Parameters:
    ///   - connectionId: The unique identifier of the connection to monitor.
    ///   - pingHandler: Closure that executes a lightweight query (e.g., `SELECT 1`)
    ///     and returns `true` if the connection is alive.
    ///   - reconnectHandler: Closure that attempts to re-establish the connection
    ///     and returns `true` on success.
    ///   - onStateChanged: Closure invoked whenever the health state transitions.
    init(
        connectionId: UUID,
        pingHandler: @escaping @Sendable () async -> Bool,
        reconnectHandler: @escaping @Sendable () async -> Bool,
        onStateChanged: @escaping @Sendable (UUID, HealthState) async -> Void
    ) {
        self.connectionId = connectionId
        self.pingHandler = pingHandler
        self.reconnectHandler = reconnectHandler
        self.onStateChanged = onStateChanged
    }

    // MARK: - Public API

    /// The current health state of the monitored connection.
    var currentState: HealthState {
        state
    }

    /// Starts periodic health monitoring.
    ///
    /// Creates a long-running task that pings the connection every 30 seconds.
    /// If monitoring is already active, this method does nothing.
    func startMonitoring() {
        guard monitoringTask == nil else {
            Self.logger.trace("Monitoring already active for connection \(self.connectionId)")
            return
        }

        Self.logger.trace("Starting health monitoring for connection \(self.connectionId)")

        let (wakeUpStream, continuation) = AsyncStream<Void>.makeStream()
        self.wakeUpContinuation = continuation

        monitoringTask = Task { [weak self] in
            guard let self else { return }

            let initialDelay = Double.random(in: 0 ... 10)
            try? await Task.sleep(for: .seconds(initialDelay))
            guard !Task.isCancelled else { return }

            while !Task.isCancelled {
                // Race between the normal ping interval and an early wake-up signal
                await withTaskGroup(of: Bool.self) { group in
                    group.addTask {
                        try? await Task.sleep(for: .seconds(Self.pingInterval))
                        return false // normal timer fired
                    }
                    group.addTask {
                        var iterator = wakeUpStream.makeAsyncIterator()
                        _ = await iterator.next()
                        return true // woken up early
                    }

                    // Wait for whichever finishes first, cancel the other
                    if await group.next() != nil {
                        group.cancelAll()
                    }
                }

                guard !Task.isCancelled else { break }

                await self.performHealthCheck()
            }

            Self.logger.trace("Monitoring loop exited for connection \(self.connectionId)")
        }
    }

    /// Stops periodic health monitoring and cancels any in-flight reconnect attempts.
    func stopMonitoring() {
        Self.logger.trace("Stopping health monitoring for connection \(self.connectionId)")
        monitoringTask?.cancel()
        monitoringTask = nil
        wakeUpContinuation?.finish()
        wakeUpContinuation = nil
    }

    /// Triggers an immediate health check, interrupting the normal 30-second sleep.
    ///
    /// Call this after a query failure to get faster feedback on connection health
    /// instead of waiting for the next scheduled ping.
    func checkNow() {
        wakeUpContinuation?.yield()
    }

    /// Resets the monitor to `.healthy` after the user manually reconnects.
    ///
    /// Call this when an external reconnection succeeds so the monitor resumes
    /// normal periodic pings instead of staying in `.failed` state.
    func resetAfterManualReconnect() async {
        Self.logger.info("Manual reconnect succeeded, resetting to healthy for connection \(self.connectionId)")
        await transitionTo(.healthy)
    }

    // MARK: - Health Check

    /// Performs a single health check cycle.
    ///
    /// Skips the check if the monitor is already in a non-healthy state
    /// (e.g., mid-reconnect). On ping failure, triggers the reconnect sequence.
    private func performHealthCheck() async {
        guard state == .healthy else {
            Self.logger.debug("Skipping health check — state is \(String(describing: self.state)) for connection \(self.connectionId)")
            return
        }

        await transitionTo(.checking)

        let isAlive = await pingHandler()

        if isAlive {
            await transitionTo(.healthy)
        } else {
            Self.logger.warning("Ping failed for connection \(self.connectionId), starting reconnect sequence")
            await attemptReconnect()
        }
    }

    // MARK: - Reconnection

    /// Attempts to reconnect with exponential backoff.
    ///
    /// Uses initial delays of 2s, 4s, 8s, then continues doubling up to a
    /// 120-second cap. Transitions to `.failed` only when the task is cancelled
    /// (i.e., the monitor is stopped). This ensures the monitor keeps trying
    /// indefinitely rather than giving up after a fixed number of attempts.
    private func attemptReconnect() async {
        var attempt = 0

        while !Task.isCancelled {
            attempt += 1

            let delay = backoffDelay(for: attempt)

            Self.logger.warning("Reconnect attempt \(attempt) for connection \(self.connectionId) — waiting \(delay)s")
            await transitionTo(.reconnecting(attempt: attempt))

            try? await Task.sleep(for: .seconds(delay))

            guard !Task.isCancelled else {
                Self.logger.debug("Reconnect cancelled during backoff for connection \(self.connectionId)")
                return
            }

            let success = await reconnectHandler()

            if success {
                Self.logger.info("Reconnect succeeded on attempt \(attempt) for connection \(self.connectionId)")
                await transitionTo(.healthy)
                return
            }

            Self.logger.warning("Reconnect attempt \(attempt) failed for connection \(self.connectionId)")
        }

        Self.logger.error("Reconnect cancelled after \(attempt) attempts for connection \(self.connectionId)")
        await transitionTo(.failed)
    }

    /// Computes the backoff delay for a given attempt number (1-based).
    ///
    /// Uses the initial delay table for the first few attempts, then doubles
    /// the previous delay for subsequent attempts, capped at `maxBackoffDelay`.
    private func backoffDelay(for attempt: Int) -> TimeInterval {
        let delays = Self.initialBackoffDelays
        if attempt <= delays.count {
            return delays[attempt - 1]
        }
        // Exponential: last seed delay * 2^(attempt - seedCount)
        let lastSeed = delays[delays.count - 1]
        let exponent = attempt - delays.count
        let computed = lastSeed * pow(2.0, Double(exponent))
        return min(computed, Self.maxBackoffDelay)
    }

    // MARK: - State Transitions

    /// Transitions to a new health state, logging the change and notifying observers.
    private func transitionTo(_ newState: HealthState) async {
        let oldState = state
        state = newState

        if oldState != newState {
            // Skip logging for routine healthy ↔ checking cycle (every 30s)
            let isRoutineCycle = (oldState == .healthy && newState == .checking)
                || (oldState == .checking && newState == .healthy)
            if !isRoutineCycle {
                Self.logger.log(
                    level: logLevel(for: newState),
                    "Connection \(self.connectionId) health state: \(String(describing: oldState)) -> \(String(describing: newState))"
                )
            }

            await onStateChanged(connectionId, newState)
        }
    }

    /// Returns the appropriate log level for a given health state.
    private func logLevel(for state: HealthState) -> OSLogType {
        switch state {
        case .healthy, .checking:
            return .debug
        case .reconnecting:
            return .default
        case .failed:
            return .error
        }
    }
}
