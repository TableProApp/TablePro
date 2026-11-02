//
//  ConnectionHealthMonitor.swift
//  TablePro
//

import Foundation
import os

extension ConnectionHealthMonitor {
    enum HealthState: Sendable, Equatable {
        case healthy
        case checking
        // The session's reconnect loop took the failure over, so this monitor has nothing left to ask.
        case handedOff
    }

    enum FailureHandling: Sendable, Equatable {
        case handedOff
        case ignored
    }
}

// Notices a connection that stopped answering. Redialing belongs to the session's reconnect loop.
actor ConnectionHealthMonitor {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ConnectionHealthMonitor")

    private let connectionId: UUID
    // Asked on every pass, so a change to the setting reaches open connections; nil ends the loop (#2700).
    private let pingInterval: @Sendable () async -> Duration?
    private let pingHandler: @Sendable () async -> Bool
    private let failureHandler: @Sendable () async -> FailureHandling

    private var state: HealthState = .healthy
    private var monitoringTask: Task<Void, Never>?
    private var pingCount: Int = 0
    private var lastPingTime: ContinuousClock.Instant?

    init(
        connectionId: UUID,
        pingInterval: @escaping @Sendable () async -> Duration?,
        pingHandler: @escaping @Sendable () async -> Bool,
        onPingFailed: @escaping @Sendable () async -> FailureHandling
    ) {
        self.connectionId = connectionId
        self.pingInterval = pingInterval
        self.pingHandler = pingHandler
        self.failureHandler = onPingFailed
    }

    var currentState: HealthState {
        state
    }

    var hasHandedOff: Bool {
        state == .handedOff
    }

    func startMonitoring() {
        guard monitoringTask == nil else {
            Self.logger.trace("Monitoring already active for connection \(self.connectionId)")
            return
        }

        Self.logger.trace("Starting health monitoring for connection \(self.connectionId)")

        let intervalForPass = pingInterval
        monitoringTask = Task { [weak self] in
            guard let self else { return }

            let initialDelay = Double.random(in: 0 ... 10)
            try? await Task.sleep(for: .seconds(initialDelay))
            guard !Task.isCancelled else { return }

            while !Task.isCancelled {
                guard let interval = await intervalForPass() else { break }
                // The tolerance lets the system coalesce every open connection's ping into one wake.
                try? await Task.sleep(for: interval, tolerance: interval / 4)
                guard !Task.isCancelled else { break }
                // Asked again after the sleep, so turning checks off stops the next one.
                guard await intervalForPass() != nil else { break }
                await self.performHealthCheck()
                guard await !self.hasHandedOff else { break }
            }

            Self.logger.trace("Monitoring loop exited for connection \(self.connectionId)")
        }
    }

    // Awaits the task, so no orphaned ping runs after a new monitor starts.
    func stopMonitoring() async {
        Self.logger.trace("Stopping health monitoring for connection \(self.connectionId)")
        let task = monitoringTask
        monitoringTask = nil
        task?.cancel()
        await task?.value
    }

    internal func performHealthCheck() async {
        guard state == .healthy else {
            Self.logger.debug("Skipping health check, state is \(String(describing: self.state)) for connection \(self.connectionId)")
            return
        }

        pingCount += 1
        let now = ContinuousClock.now
        if let last = lastPingTime {
            let interval = (now - last) / .seconds(1)
            if interval < 5.0 {
                Self.logger.warning(
                    "Ping #\(self.pingCount) fired only \(String(format: "%.2f", interval))s after previous for \(self.connectionId)"
                )
            } else {
                Self.logger.debug("Ping #\(self.pingCount) for \(self.connectionId) (interval: \(String(format: "%.1f", interval))s)")
            }
        } else {
            Self.logger.debug("First ping (#\(self.pingCount)) for \(self.connectionId)")
        }
        lastPingTime = now

        state = .checking
        if await pingHandler() {
            state = .healthy
            return
        }

        Self.logger.warning("Ping failed for connection \(self.connectionId)")
        switch await failureHandler() {
        case .handedOff:
            state = .handedOff
        case .ignored:
            state = .healthy
        }
    }
}
