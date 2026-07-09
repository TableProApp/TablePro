//
//  PasswordSourceResolverTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("PasswordSourceResolver command output")
struct PasswordSourceResolverTests {
    @Test("Command stdout is returned trimmed")
    func returnsTrimmedStdout() async throws {
        let output = try await PasswordSourceResolver.resolveCommand(
            shell: "printf '  hunter2\\n'",
            timeoutSeconds: 5
        )
        #expect(output == "hunter2")
    }

    @Test("Large stdout drains in full and in order while stderr is also draining")
    func drainsLargeStdoutWithoutTruncation() async throws {
        let shell = """
        head -c 300000 /dev/zero | tr '\\0' 'a'
        head -c 300000 /dev/zero | tr '\\0' 'b' >&2
        """
        let output = try await PasswordSourceResolver.resolveCommand(shell: shell, timeoutSeconds: 30)
        #expect(output.count == 300_000)
        #expect(output.allSatisfy { $0 == "a" })
    }

    @Test("A failing command surfaces the exit code and stderr")
    func failingCommandSurfacesStderr() async throws {
        do {
            _ = try await PasswordSourceResolver.resolveCommand(
                shell: "printf boom >&2; exit 7",
                timeoutSeconds: 5
            )
            Issue.record("Expected resolveCommand to throw")
        } catch let PasswordSourceResolver.ResolutionError.commandFailed(exitCode, stderr) {
            #expect(exitCode == 7)
            #expect(stderr.contains("boom"))
        }
    }

    @Test("Output over the size cap fails as too large")
    func overflowFailsAsTooLarge() async throws {
        do {
            _ = try await PasswordSourceResolver.resolveCommand(
                shell: "yes | head -c 1200000",
                timeoutSeconds: 30
            )
            Issue.record("Expected outputTooLarge")
        } catch PasswordSourceResolver.ResolutionError.outputTooLarge {
        }
    }

    @Test("A command that exceeds the timeout is terminated")
    func timeoutTerminatesCommand() async throws {
        do {
            _ = try await PasswordSourceResolver.resolveCommand(
                shell: "sleep 30",
                timeoutSeconds: 1
            )
            Issue.record("Expected commandTimedOut")
        } catch PasswordSourceResolver.ResolutionError.commandTimedOut {
        }
    }

    @Test("Empty output fails as an empty password")
    func emptyOutputFailsAsEmpty() async throws {
        do {
            _ = try await PasswordSourceResolver.resolveCommand(
                shell: "true",
                timeoutSeconds: 5
            )
            Issue.record("Expected emptyPassword")
        } catch PasswordSourceResolver.ResolutionError.emptyPassword {
        }
    }
}
