//
//  StaleProcessReaper.swift
//  TablePro
//

import Darwin
import Foundation
import os

/// Terminates helper processes a previous session left behind, and does not return until they are
/// actually gone.
///
/// A crash or force-quit leaves `cloudflared` or `cloud-sql-proxy` running, still holding the local
/// port it was told to listen on. Signalling it and returning is not enough: a connection with a
/// fixed local port gets one attempt at that port, so a replacement started while the orphan is
/// still exiting fails with an address already in use. The reaper therefore signals, polls until the
/// process is gone, escalates once, and reports whatever survived so the caller can keep its record
/// and try again next launch.
///
/// These processes are not this process's children, so `waitpid` is unavailable and polling
/// `proc_pidpath` is the only way to see them exit.
internal enum StaleProcessReaper {
    internal struct Target: Sendable, Equatable {
        internal let pid: pid_t
        internal let binaryPath: String
        internal let executableName: String

        internal init(pid: pid_t, binaryPath: String, executableName: String) {
            self.pid = pid
            self.binaryPath = binaryPath
            self.executableName = executableName
        }
    }

    internal struct Timings: Sendable {
        internal let grace: Duration
        internal let forcedGrace: Duration
        internal let poll: Duration

        internal init(grace: Duration, forcedGrace: Duration, poll: Duration) {
            self.grace = grace
            self.forcedGrace = forcedGrace
            self.poll = poll
        }

        /// `cloudflared` and `cloud-sql-proxy` both close their listener and exit on `SIGTERM` well
        /// inside the grace period. It is long enough that the escalation is the rare path, and the
        /// wait is only ever paid by a connection that would otherwise have failed outright.
        internal static let production = Timings(
            grace: .seconds(2),
            forcedGrace: .milliseconds(500),
            poll: .milliseconds(50)
        )
    }

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "StaleProcessReaper")

    /// A pid the OS recycled after the crash belongs to something else, so the executable behind it
    /// is checked before every signal rather than once at the start.
    internal static func isLive(_ target: Target) -> Bool {
        guard target.pid > 0 else { return false }
        let bufferSize = 4 * Int(PATH_MAX)
        var buffer = [CChar](repeating: 0, count: bufferSize)
        let length = proc_pidpath(target.pid, &buffer, UInt32(bufferSize))
        guard length > 0 else { return false }
        let path = String(cString: buffer)
        if !target.binaryPath.isEmpty, path == target.binaryPath { return true }
        return (path as NSString).lastPathComponent == target.executableName
    }

    /// Returns the targets still running when the reaper gave up, which is empty in every ordinary
    /// case.
    internal static func reap(
        _ targets: [Target],
        timings: Timings = .production,
        isLive: @Sendable (Target) -> Bool = StaleProcessReaper.isLive,
        signal send: @Sendable (pid_t, Int32) -> Void = { kill($0, $1) }
    ) async -> [Target] {
        var live = targets.filter(isLive)
        guard !live.isEmpty else { return [] }

        for target in live {
            send(target.pid, SIGTERM)
            logger.notice("Signalled stale \(target.executableName, privacy: .public) pid \(target.pid)")
        }

        live = await waitForExit(of: live, within: timings.grace, poll: timings.poll, isLive: isLive)
        guard !live.isEmpty else { return [] }

        for target in live {
            send(target.pid, SIGKILL)
            logger.warning(
                "Stale \(target.executableName, privacy: .public) pid \(target.pid) ignored SIGTERM, forcing"
            )
        }

        live = await waitForExit(of: live, within: timings.forcedGrace, poll: timings.poll, isLive: isLive)
        for target in live {
            logger.error(
                "Stale \(target.executableName, privacy: .public) pid \(target.pid) survived, keeping its record"
            )
        }
        return live
    }

    private static func waitForExit(
        of targets: [Target],
        within budget: Duration,
        poll: Duration,
        isLive: @Sendable (Target) -> Bool
    ) async -> [Target] {
        var remaining = targets.filter(isLive)
        guard !remaining.isEmpty else { return [] }

        let deadline = ContinuousClock.now.advanced(by: budget)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: poll)
            remaining = remaining.filter(isLive)
            if remaining.isEmpty { return [] }
        }
        return remaining
    }
}
