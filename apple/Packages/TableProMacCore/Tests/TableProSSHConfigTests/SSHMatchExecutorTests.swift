import Foundation
import Testing

@testable import TableProSSHConfig

struct SSHMatchExecutorTests {
    @Test("Exit 0 matches")
    func exitZeroMatches() {
        #expect(SSHMatchExecutor.evaluate(command: "true"))
    }

    @Test("Non-zero exit does not match")
    func nonZeroDoesNotMatch() {
        #expect(!SSHMatchExecutor.evaluate(command: "false"))
    }

    @Test("Empty command does not match")
    func emptyDoesNotMatch() {
        #expect(!SSHMatchExecutor.evaluate(command: ""))
        #expect(!SSHMatchExecutor.evaluate(command: "   "))
    }

    // Process hands U+037E over as `;`, so the shell would have run the touch.
    @Test("A command the launcher refuses never runs and does not match")
    func refusedCommandDoesNotRun() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("match-exec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let marker = folder.appendingPathComponent("ran")

        #expect(!SSHMatchExecutor.evaluate(command: "true\u{37E}touch \(marker.path)"))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(!SSHMatchExecutor.evaluate(command: "true\u{0}"))
    }

    @Test("Slow command times out and does not match")
    func timeoutDoesNotMatch() {
        #expect(SSHMatchExecutor.timeoutSeconds > 0)
        #expect(SSHMatchExecutor.timeoutSeconds < 6, "The connect path must stop a 6 second command")
        #expect(!SSHMatchExecutor.evaluate(command: "sleep 6", timeout: 0.1))
    }
}
