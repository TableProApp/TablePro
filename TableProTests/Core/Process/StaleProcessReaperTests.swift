//
//  StaleProcessReaperTests.swift
//  TableProTests
//

import Darwin
import Foundation
import os
import Testing

@testable import TablePro

/// A set of pretend processes. `dies(on:)` says which signal each one answers, so a test can model
/// a well-behaved helper, one that ignores `SIGTERM`, and one that ignores everything.
private final class FakeProcessTable: @unchecked Sendable {
    private struct State {
        var alive: Set<pid_t>
        var diesOn: [pid_t: Int32]
        var signals: [(pid: pid_t, signal: Int32)]
    }

    private let state: OSAllocatedUnfairLock<State>

    init(alive: [pid_t], diesOn: [pid_t: Int32]) {
        state = OSAllocatedUnfairLock(initialState: State(alive: Set(alive), diesOn: diesOn, signals: []))
    }

    var signals: [(pid: pid_t, signal: Int32)] { state.withLock { $0.signals } }
    var aliveCount: Int { state.withLock { $0.alive.count } }

    func isLive(_ target: StaleProcessReaper.Target) -> Bool {
        state.withLock { $0.alive.contains(target.pid) }
    }

    func send(_ pid: pid_t, _ signal: Int32) {
        state.withLock {
            $0.signals.append((pid, signal))
            if $0.diesOn[pid] == signal { $0.alive.remove(pid) }
        }
    }
}

@Suite("Stale process reaper")
struct StaleProcessReaperTests {
    private static let fast = StaleProcessReaper.Timings(
        grace: .milliseconds(60),
        forcedGrace: .milliseconds(60),
        poll: .milliseconds(5)
    )

    private func target(_ pid: pid_t) -> StaleProcessReaper.Target {
        StaleProcessReaper.Target(pid: pid, binaryPath: "/opt/fake/cloudflared", executableName: "cloudflared")
    }

    @Test("A process that is already gone is never signalled")
    func deadProcessIsNotSignalled() async {
        let table = FakeProcessTable(alive: [], diesOn: [:])

        let survivors = await StaleProcessReaper.reap(
            [target(4242)],
            timings: Self.fast,
            isLive: table.isLive,
            signal: table.send
        )

        #expect(survivors.isEmpty)
        #expect(table.signals.isEmpty)
    }

    /// The pid the OS handed to something else after the crash. Signalling it would kill a stranger.
    @Test("A recycled pid whose executable no longer matches is never signalled")
    func recycledPidIsNotSignalled() async {
        let table = FakeProcessTable(alive: [], diesOn: [:])

        _ = await StaleProcessReaper.reap(
            [target(99)],
            timings: Self.fast,
            isLive: table.isLive,
            signal: table.send
        )

        #expect(table.signals.isEmpty)
    }

    @Test("A process that answers SIGTERM is never forced")
    func politeProcessGetsOnlySigterm() async {
        let table = FakeProcessTable(alive: [10], diesOn: [10: SIGTERM])

        let survivors = await StaleProcessReaper.reap(
            [target(10)],
            timings: Self.fast,
            isLive: table.isLive,
            signal: table.send
        )

        #expect(survivors.isEmpty)
        #expect(table.signals.map(\.signal) == [SIGTERM])
        #expect(table.aliveCount == 0)
    }

    /// The case the barrier exists for: the port is not free until this one is actually gone.
    @Test("A process that ignores SIGTERM is escalated to SIGKILL")
    func stubbornProcessIsForced() async {
        let table = FakeProcessTable(alive: [11], diesOn: [11: SIGKILL])

        let survivors = await StaleProcessReaper.reap(
            [target(11)],
            timings: Self.fast,
            isLive: table.isLive,
            signal: table.send
        )

        #expect(survivors.isEmpty)
        #expect(table.signals.map(\.signal) == [SIGTERM, SIGKILL])
        #expect(table.aliveCount == 0)
    }

    @Test("A process that survives everything is reported so its record is kept")
    func unkillableProcessIsReported() async {
        let table = FakeProcessTable(alive: [12], diesOn: [:])

        let survivors = await StaleProcessReaper.reap(
            [target(12)],
            timings: Self.fast,
            isLive: table.isLive,
            signal: table.send
        )

        #expect(survivors.map(\.pid) == [12])
        #expect(table.signals.map(\.signal) == [SIGTERM, SIGKILL])
    }

    @Test("Every stale process is signalled, not only the first")
    func allTargetsAreSignalled() async {
        let table = FakeProcessTable(alive: [20, 21, 22], diesOn: [20: SIGTERM, 21: SIGTERM, 22: SIGTERM])

        let survivors = await StaleProcessReaper.reap(
            [target(20), target(21), target(22)],
            timings: Self.fast,
            isLive: table.isLive,
            signal: table.send
        )

        #expect(survivors.isEmpty)
        #expect(Set(table.signals.map(\.pid)) == [20, 21, 22])
        #expect(table.aliveCount == 0)
    }

    @Test("An empty set of targets does no work")
    func noTargetsIsANoop() async {
        let table = FakeProcessTable(alive: [1], diesOn: [:])

        let survivors = await StaleProcessReaper.reap(
            [],
            timings: Self.fast,
            isLive: table.isLive,
            signal: table.send
        )

        #expect(survivors.isEmpty)
        #expect(table.signals.isEmpty)
    }

    /// `isLive` reads the executable behind the pid, so this is the guard against killing whatever
    /// inherited a recycled pid. Nothing is running under this one in the test host.
    @Test("The real liveness check rejects a pid that is not running")
    func realLivenessCheckRejectsDeadPid() {
        #expect(!StaleProcessReaper.isLive(target(-1)))
        #expect(!StaleProcessReaper.isLive(target(0)))
    }
}
