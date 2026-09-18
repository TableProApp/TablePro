//
//  LaunchTracer.swift
//  TablePro
//

import Darwin
import Foundation
import os

/// Time tracing for the launch path: process exec, `main`, the two delegate callbacks, intent
/// routing, and the frame the first window actually presents.
///
/// Stage lines are logged at debug level, so they cost nothing until capture is turned on
/// (`log stream --level debug --predicate 'subsystem == "com.TablePro"'`). Every stage is also an
/// Instruments event under Points of Interest, and the whole launch is one interval there.
///
/// `TABLEPRO_LAUNCH_TRACE=1` additionally writes the finished table to standard error, which is how
/// a launch is measured from a script without attaching Instruments.
@MainActor
internal final class LaunchTracer {
    internal static let shared = LaunchTracer()

    internal enum Stage: String {
        case main
        case storageResolved
        case applicationCreated
        case activationRoleApplied
        case willFinishLaunchingBegan
        case menuInstalled
        case pluginsDiscovered
        case willFinishLaunchingEnded
        case didFinishLaunchingBegan
        case didFinishLaunchingEnded
        case intentsRouted
        case firstWindowOrdered
        case firstFramePresented
    }

    internal struct Mark: Equatable {
        internal let stage: Stage
        internal let offset: TimeInterval
    }

    nonisolated private static let dumpsToStandardError =
        ProcessInfo.processInfo.environment["TABLEPRO_LAUNCH_TRACE"] == "1"

    nonisolated private let logger = Logger(subsystem: "com.TablePro", category: "Launch")
    nonisolated private let signposter = OSSignposter(subsystem: "com.TablePro", category: .pointsOfInterest)

    private let processStart: Date
    private var marks: [Mark] = []
    private var interval: OSSignpostIntervalState?
    private var signpostID: OSSignpostID?
    private var hasFinished = false

    internal init(processStart: Date = LaunchTracer.processStartDate()) {
        self.processStart = processStart
    }

    /// Seconds since the kernel started this process, which is the only number a person waiting for
    /// the app can feel. Starting the clock at `main` hides dyld, and `ProcessInfo.systemUptime`
    /// read at first touch starts it wherever this type happened to be reached first.
    internal var elapsed: TimeInterval {
        Date().timeIntervalSince(processStart)
    }

    internal var recordedMarks: [Mark] { marks }

    internal func mark(_ stage: Stage) {
        guard !hasFinished else { return }
        let offset = elapsed
        marks.append(Mark(stage: stage, offset: offset))

        let id = signpostID ?? beginInterval()
        signposter.emitEvent("LaunchStage", id: id, "\(stage.rawValue, privacy: .public)")
        logger.debug("launch \(stage.rawValue, privacy: .public) at \(Int(offset * 1_000), privacy: .public)ms")

        guard stage == .firstFramePresented else { return }
        finish()
    }

    internal func report() -> String {
        var lines = ["launch trace (ms since exec)"]
        var previous: TimeInterval = 0
        for mark in marks {
            lines.append(String(
                format: "  %-26@ %8.1f  (+%6.1f)",
                mark.stage.rawValue as NSString,
                mark.offset * 1_000,
                (mark.offset - previous) * 1_000
            ))
            previous = mark.offset
        }
        return lines.joined(separator: "\n")
    }

    private func beginInterval() -> OSSignpostID {
        let id = signposter.makeSignpostID()
        signpostID = id
        interval = signposter.beginInterval("AppLaunch", id: id)
        return id
    }

    private func finish() {
        hasFinished = true
        let total = Int(elapsed * 1_000)
        if let interval {
            signposter.endInterval("AppLaunch", interval, "\(total, privacy: .public)ms")
        }
        logger.info("launch ready in \(total, privacy: .public)ms")
        guard Self.dumpsToStandardError else { return }
        FileHandle.standardError.write(Data("\n\(report())\n".utf8))
    }

    /// `kinfo_proc.kp_proc.p_starttime` is the only source for when the kernel started this process.
    nonisolated internal static func processStartDate() -> Date {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, ProcessInfo.processInfo.processIdentifier]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0 else { return Date() }
        let started = info.kp_proc.p_starttime
        return Date(
            timeIntervalSince1970: TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000
        )
    }
}
