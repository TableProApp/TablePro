//
//  ProcessNativeDumpRunnerTests.swift
//  TableProTests
//

import Darwin
import Foundation
import Testing

@testable import TablePro

struct ProcessNativeDumpRunnerTests {
    private func command(_ script: String) -> NativeDumpCommand {
        NativeDumpCommand(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            environment: [:],
            stderrByteCap: 64_000
        )
    }

    @Test("A tool that exits at once still has everything it said")
    func stderrSurvivesAnImmediateExit() async throws {
        let message = "/opt/homebrew/bin/mysqldump: unknown variable 'ssl-mode=PREFERRED'"
        let runner = ProcessNativeDumpRunner(command: command("printf '%s' \"\(message)\" >&2; exit 7"))
        try runner.start()
        let result = await runner.result
        #expect(result.exitCode == 7)
        #expect(result.stderr == message)
        #expect(!result.wasCancelled)
    }

    @Test("A tool that says nothing reports its exit code alone")
    func silentFailure() async throws {
        let runner = ProcessNativeDumpRunner(command: command("exit 3"))
        try runner.start()
        let result = await runner.result
        #expect(result.exitCode == 3)
        #expect(result.stderr.isEmpty)
    }

    @Test("Output from a surviving child cannot grow the buffer past its cap", .timeLimit(.minutes(1)))
    func outputAfterExitIsBounded() async throws {
        let cap = 4_096
        let script = """
            (i=0; while [ $i -lt 400 ]; do printf '%s' \
            'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' >&2; i=$((i+1)); done) &
            printf '%s' 'first' >&2
            exit 4
            """
        let runner = ProcessNativeDumpRunner(
            command: NativeDumpCommand(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", script],
                environment: [:],
                stderrByteCap: cap
            )
        )
        try runner.start()
        let result = await runner.result
        #expect(result.exitCode == 4)
        #expect(result.stderr.utf8.count <= cap)
    }

    @Test(
        "A stderr callback dispatched before the tool exited leaves the pipe alone once the result is in",
        .timeLimit(.minutes(1))
    )
    func lateStderrCallbackLeavesThePipeAlone() async throws {
        let gate = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-dump-gate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: gate) }
        let pipe = Pipe()
        defer { withExtendedLifetime(pipe) {} }
        let survivingDescriptor = dup(pipe.fileHandleForWriting.fileDescriptor)
        try #require(survivingDescriptor >= 0)
        let survivingWriter = FileHandle(fileDescriptor: survivingDescriptor, closeOnDealloc: true)
        defer { try? survivingWriter.close() }

        let script = """
            i=0
            while [ ! -e '\(gate.path)' ] && [ $i -lt 1000 ]; do sleep 0.01; i=$((i+1)); done
            [ -e '\(gate.path)' ] || exit 9
            printf '%s' 'refused' >&2
            exit 5
            """
        let runner = ProcessNativeDumpRunner(command: command(script), stderrPipe: pipe)
        try runner.start()
        defer { runner.cancel() }
        let handle = pipe.fileHandleForReading
        let dispatched = try #require(handle.readabilityHandler)
        #expect(FileManager.default.createFile(atPath: gate.path, contents: nil))

        let writer = HeldOpenWriter(survivingWriter)
        let result = try #require(await writer.finished { await runner.result })
        #expect(result.exitCode == 5)
        #expect(result.stderr == "refused")

        try survivingWriter.write(contentsOf: Data("late".utf8))
        let returned: Void? = await writer.finishedOnItsOwnThread { dispatched(handle) }

        try #require(returned != nil)
        let descriptor = handle.fileDescriptor
        #expect(handle.readabilityHandler == nil)
        #expect(fcntl(descriptor, F_GETFL) & O_NONBLOCK == 0)
        try survivingWriter.close()
        #expect(try DescriptorRead.availableBytes(from: descriptor) == Data("late".utf8))
    }
}
