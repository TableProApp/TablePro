//
//  SnowflakeHeartbeat.swift
//  SnowflakeDriverPlugin
//
//  Keeps the Snowflake session alive while the connection is idle, mirroring
//  CLIENT_SESSION_KEEP_ALIVE in the official drivers: one heartbeat every
//  quarter of the master token validity, clamped to 15 to 60 minutes.
//

import Foundation

actor SnowflakeHeartbeat {
    static let minimumInterval: TimeInterval = 900
    static let maximumInterval: TimeInterval = 3_600

    private var task: Task<Void, Never>?

    static func interval(masterValiditySeconds: TimeInterval) -> TimeInterval {
        min(maximumInterval, max(minimumInterval, masterValiditySeconds / 4))
    }

    func start(interval: TimeInterval, beat: @escaping @Sendable () async -> Void) {
        task?.cancel()
        task = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await beat()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
