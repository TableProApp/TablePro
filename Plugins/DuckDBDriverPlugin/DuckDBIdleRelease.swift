//
//  DuckDBIdleRelease.swift
//  DuckDBDriverPlugin
//
//  The idle-release policy and its timer. No CDuckDB import, so TableProTests can
//  exercise both without loading the plugin bundle.
//

import Foundation

/// How long a DuckDB connection may sit unused before it gives the file's lock back.
///
/// The value is minutes, stored on the connection, and zero means never. Zero is the default
/// because a release is not free: DuckDB destroys a session's temp objects, its settings, its
/// attached catalogs and its `USE` position when the handle closes, and an open transaction is
/// rolled back with nothing raised. The driver refuses to release while it holds any of those,
/// so the feature is safe once it is on, but a connection that never releases is what a user
/// who has not asked for this should get.
enum DuckDBIdleRelease {
    static let fieldId = "duckdbIdleReleaseMinutes"

    /// Four hours. Past this the setting is indistinguishable from never, and a stepper with a
    /// bound a user can reach beats a free-text field that accepts a year.
    static let maximumMinutes = 240

    static let neverValue = "0"

    /// Nil for never, which covers the default, an absent field, a blank one, zero, a negative
    /// number and anything that is not a number at all. A malformed value releasing the lock on
    /// some interval nobody chose is worse than one that does nothing.
    static func minutes(fromFieldValue value: String?) -> Int? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty,
              let minutes = Int(trimmed), minutes > 0
        else { return nil }
        return min(minutes, maximumMinutes)
    }

    static func interval(fromFieldValue value: String?) -> Duration? {
        minutes(fromFieldValue: value).map { .seconds($0 * 60) }
    }

    /// The timer wakes more often than the interval so a connection that goes idle just after a
    /// tick does not wait a whole second interval, and never so often that a four-hour setting
    /// spends the day waking up.
    static func pollInterval(for idleInterval: Duration) -> Duration {
        let quarter = idleInterval / 4
        return max(.seconds(5), min(quarter, .seconds(60)))
    }
}

/// Wakes on a schedule and asks whether the connection has been idle long enough to release.
/// Modelled on `SnowflakeHeartbeat`: an actor owning one `Task` that loops on `Task.sleep`, so
/// cancelling the task is the whole of stopping it.
///
/// It decides nothing itself. Whether a release is safe is the connection actor's call, made
/// against the live session under the same actor that would close the handle, because the answer
/// changes the moment the user runs a statement.
actor DuckDBIdleReleaseTimer {
    private var task: Task<Void, Never>?

    func start(interval: Duration, onTick: @escaping @Sendable () async -> Void) {
        stop()
        let poll = DuckDBIdleRelease.pollInterval(for: interval)
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
