//
//  MySQLIdleRelease.swift
//  MySQLDriverPlugin
//
//  The idle-release policy and its timer. No CMariaDB import, so TableProTests can
//  exercise both without loading the plugin bundle.
//

import Foundation

/// How long a MySQL connection may sit unused before it hands its server connection back.
///
/// Zero, the default, means never, and that default is not timidity. Measured against MariaDB
/// 12.3.3, an idle connection costs the server about 186KB and one slot of 151, and nothing is
/// blocked on it, so the prize is small. Re-taking one is not: measured, `mysql_real_connect`
/// costs 1.7-5.8ms on loopback but 800-1900ms against a server across the internet, three to five
/// round trips including the TLS handshake and auth. Past roughly 50ms of latency this trades a
/// free connection slot for a visibly slower first query, which is a trade only the person using
/// it can make.
enum MySQLIdleRelease {
    static let fieldId = "mysqlIdleReleaseMinutes"

    static let maximumMinutes = 240

    static let neverValue = "0"

    /// Nil for never, which covers the default, an absent field, a blank one, zero, a negative
    /// number and anything that is not a number at all.
    static func minutes(fromFieldValue value: String?) -> Int? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty,
              let minutes = Int(trimmed), minutes > 0
        else { return nil }
        return min(minutes, maximumMinutes)
    }

    static func interval(fromFieldValue value: String?) -> Duration? {
        minutes(fromFieldValue: value).map { .seconds($0 * 60) }
    }

    static func pollInterval(for idleInterval: Duration) -> Duration {
        let quarter = idleInterval / 4
        return max(.seconds(5), min(quarter, .seconds(60)))
    }
}

/// Wakes on a schedule and asks whether the connection has been idle long enough to release.
/// The same shape as `SnowflakeHeartbeat`: one `Task` looping on `Task.sleep`, so cancelling the
/// task is the whole of stopping it.
actor MySQLIdleReleaseTimer {
    private var task: Task<Void, Never>?

    func start(interval: Duration, onTick: @escaping @Sendable () async -> Void) {
        stop()
        let poll = MySQLIdleRelease.pollInterval(for: interval)
        task = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: poll)
                guard !Task.isCancelled else { return }
                await onTick()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
