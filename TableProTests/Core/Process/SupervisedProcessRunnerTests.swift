//
//  SupervisedProcessRunnerTests.swift
//  TableProTests
//

import Darwin
import Foundation
import Testing

@testable import TablePro

@Suite("Supervised process runner")
struct SupervisedProcessRunnerTests {
    private func runner(script: String) throws -> ProcessSupervisedRunner {
        let runner = ProcessSupervisedRunner()
        try runner.start(
            binaryPath: "/bin/sh",
            arguments: ["-c", script],
            environment: ["PATH": "/usr/bin:/bin"]
        )
        return runner
    }

    @Test("Every concurrent waiter is resumed when the process exits")
    func resumesEveryConcurrentWaiter() async throws {
        let runner = try runner(script: "exit 7")

        async let first = runner.termination
        async let second = runner.termination
        async let third = runner.termination

        let results = await [first, second, third]

        #expect(results.count == 3)
        for result in results {
            #expect(result.exitCode == 7)
            #expect(!result.wasRequested)
        }
    }

    @Test("A waiter that arrives after the process exited gets the same result")
    func resumesLateWaiter() async throws {
        let runner = try runner(script: "exit 3")

        let first = await runner.termination
        let second = await runner.termination

        #expect(first == second)
        #expect(second.exitCode == 3)
    }

    @Test("A requested stop is reported as requested")
    func reportsRequestedStop() async throws {
        let runner = try runner(script: "sleep 5")

        runner.stop()
        let result = await runner.termination

        #expect(result.wasRequested)
    }

    @Test("Standard error is delivered line by line and the stream finishes")
    func deliversStderrLines() async throws {
        let runner = try runner(script: "echo first >&2; echo second >&2; exit 0")

        var lines: [String] = []
        for await line in runner.stderrLines {
            lines.append(line)
        }

        #expect(lines == ["first", "second"])
    }

    /// The readability callback and the termination handler run on different threads, so a line
    /// read just before the process exited used to race the stream's close and lose. One run
    /// shows it rarely; a hundred in a row showed it on CI.
    @Test("A line written right before exit is delivered every time")
    func lastLineSurvivesExit() async throws {
        for _ in 0..<100 {
            let runner = try runner(script: "echo first >&2; echo second >&2; exit 0")

            var lines: [String] = []
            for await line in runner.stderrLines {
                lines.append(line)
            }

            #expect(lines == ["first", "second"])
        }
    }

    @Test("A trailing line without a newline is still delivered")
    func deliversTrailingLine() async throws {
        let runner = try runner(script: "printf 'no trailing newline' >&2; exit 0")

        var lines: [String] = []
        for await line in runner.stderrLines {
            lines.append(line)
        }

        #expect(lines == ["no trailing newline"])
    }

    private func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    private func waitUntilGone(_ pid: pid_t, within seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !isAlive(pid) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return !isAlive(pid)
    }

    /// The whole reason `stop()` may signal a negated pid: Foundation puts every child in a process
    /// group of its own. If a toolchain stopped doing that, the same call would signal this
    /// process's own group instead.
    @Test("A launched process leads its own process group")
    func processLeadsItsOwnGroup() async throws {
        let runner = try runner(script: "sleep 30")
        let pid = try #require(runner.processIdentifier)

        #expect(getpgid(pid) == pid)
        #expect(getpgid(pid) != getpgid(0))

        runner.stop()
        _ = await runner.termination
    }

    @Test("Stopping takes down a helper the command spawned for itself")
    func stopTakesDownDescendants() async throws {
        let runner = try runner(script: "sleep 40 & echo $! >&2; wait")

        var helperPid: pid_t?
        for await line in runner.stderrLines {
            helperPid = pid_t(line.trimmingCharacters(in: .whitespacesAndNewlines))
            break
        }
        let helper = try #require(helperPid)
        #expect(isAlive(helper))

        runner.stop()

        #expect(await waitUntilGone(helper, within: 5))
    }
}
