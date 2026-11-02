//
//  ProcessNativeDumpRunnerTests.swift
//  TableProTests
//

import Darwin
import Foundation
import Testing

@testable import TablePro
import TableProTestSupport
@testable import TableProUtilities

struct ProcessNativeDumpRunnerTests {
    // A stand-in dump tool: the runner refuses a shell as the executable, as it does for every app-run tool.
    private func tool(_ script: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-dump-tool-\(UUID().uuidString)")
        try ("#!/bin/sh\n" + script + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func command(
        _ executable: URL,
        arguments: [String] = [],
        stderrByteCap: Int = 64_000,
        credentials: URL? = nil
    ) -> NativeDumpCommand {
        NativeDumpCommand(
            executable: executable,
            arguments: arguments,
            environment: [:],
            stderrByteCap: stderrByteCap,
            temporaryCredentialsFileURL: credentials
        )
    }

    private func credentialsFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-dump-credentials-\(UUID().uuidString).yaml")
        try Data("password: \"x\"\n".utf8).write(to: url)
        return url
    }

    @Test("A tool that exits at once still has everything it said")
    func stderrSurvivesAnImmediateExit() async throws {
        let message = "/opt/homebrew/bin/mysqldump: unknown variable 'ssl-mode=PREFERRED'"
        let script = try tool("printf '%s' \"\(message)\" >&2; exit 7")
        defer { try? FileManager.default.removeItem(at: script) }
        let runner = ProcessNativeDumpRunner(command: command(script))
        try runner.start()
        let result = await runner.result
        #expect(result.exitCode == 7)
        #expect(result.stderr == message)
        #expect(!result.wasCancelled)
    }

    @Test("A tool that says nothing reports its exit code alone")
    func silentFailure() async throws {
        let script = try tool("exit 3")
        defer { try? FileManager.default.removeItem(at: script) }
        let runner = ProcessNativeDumpRunner(command: command(script))
        try runner.start()
        let result = await runner.result
        #expect(result.exitCode == 3)
        #expect(result.stderr.isEmpty)
    }

    @Test("Output from a surviving child cannot grow the buffer past its cap", .timeLimit(.minutes(1)))
    func outputAfterExitIsBounded() async throws {
        let cap = 4_096
        let script = try tool("""
            (i=0; while [ $i -lt 400 ]; do printf '%s' \
            'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' >&2; i=$((i+1)); done) &
            printf '%s' 'first' >&2
            exit 4
            """)
        defer { try? FileManager.default.removeItem(at: script) }
        let runner = ProcessNativeDumpRunner(command: command(script, stderrByteCap: cap))
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

        let script = try tool("""
            i=0
            while [ ! -e '\(gate.path)' ] && [ $i -lt 1000 ]; do sleep 0.01; i=$((i+1)); done
            [ -e '\(gate.path)' ] || exit 9
            printf '%s' 'refused' >&2
            exit 5
            """)
        defer { try? FileManager.default.removeItem(at: script) }
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

    @Test("A cancel that arrives before the start never launches the tool and still removes the credentials")
    func cancelBeforeStartLaunchesNothing() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-dump-ran-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let script = try tool("/usr/bin/touch '\(marker.path)'")
        defer { try? FileManager.default.removeItem(at: script) }
        let credentials = try credentialsFile()
        defer { try? FileManager.default.removeItem(at: credentials) }

        let runner = ProcessNativeDumpRunner(command: command(script, credentials: credentials))
        runner.cancel()
        try runner.start()
        let result = await runner.result

        #expect(result.wasCancelled)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(!FileManager.default.fileExists(atPath: credentials.path))
    }

    @Test("A NUL in an argument is refused as an error, and the credentials file goes with it")
    func nulArgumentIsRefused() throws {
        let script = try tool("exit 0")
        defer { try? FileManager.default.removeItem(at: script) }
        let credentials = try credentialsFile()
        defer { try? FileManager.default.removeItem(at: credentials) }

        let runner = ProcessNativeDumpRunner(
            command: command(script, arguments: ["-U", "a\u{0}b"], credentials: credentials)
        )
        #expect(throws: NativeDumpError.nulInArgument) { try runner.start() }
        #expect(!FileManager.default.fileExists(atPath: credentials.path))
    }

    @Test("A shell named as the tool is refused before it runs")
    func shellIsRefused() throws {
        let runner = ProcessNativeDumpRunner(
            command: command(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 0"])
        )
        #expect(throws: (any Error).self) { try runner.start() }
    }
}
