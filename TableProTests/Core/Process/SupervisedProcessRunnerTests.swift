//
//  SupervisedProcessRunnerTests.swift
//  TableProTests
//

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

    @Test("A trailing line without a newline is still delivered")
    func deliversTrailingLine() async throws {
        let runner = try runner(script: "printf 'no trailing newline' >&2; exit 0")

        var lines: [String] = []
        for await line in runner.stderrLines {
            lines.append(line)
        }

        #expect(lines == ["no trailing newline"])
    }
}
