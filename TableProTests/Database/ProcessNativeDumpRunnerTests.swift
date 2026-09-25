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

    /// A tool that rejects one of its arguments writes its whole complaint and exits at once, and
    /// the pipe still held those bytes when the buffer was read. Measured with a harness mirroring
    /// this class: 2 of 300 such runs captured nothing, so the sheet said "Process exited with
    /// code 7" and named no cause (#3046).
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

    /// A tool that leaves a child holding its standard error keeps the pipe open and writable after
    /// it has gone. Nothing downstream runs until the drain returns, the temporary credentials file
    /// included, so the drain stops at the cap instead of following whatever arrives next.
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

        let runner = ProcessNativeDumpRunner(
            command: command("while [ ! -e '\(gate.path)' ]; do sleep 0.01; done; printf '%s' 'refused' >&2; exit 5"),
            stderrPipe: pipe
        )
        try runner.start()
        let handle = pipe.fileHandleForReading
        let dispatched = try #require(handle.readabilityHandler)
        #expect(FileManager.default.createFile(atPath: gate.path, contents: nil))

        let result = try #require(await HeldOpenWriter(survivingWriter).finished { await runner.result })
        #expect(result.exitCode == 5)
        #expect(result.stderr == "refused")

        try survivingWriter.write(contentsOf: Data("late".utf8))
        dispatched(handle)

        let descriptor = handle.fileDescriptor
        #expect(handle.readabilityHandler == nil)
        #expect(fcntl(descriptor, F_GETFL) & O_NONBLOCK == 0)
        try survivingWriter.close()
        #expect(try DescriptorRead.availableBytes(from: descriptor) == Data("late".utf8))
    }
}
