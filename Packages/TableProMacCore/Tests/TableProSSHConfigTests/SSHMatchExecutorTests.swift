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

    @Test("Slow command times out and does not match")
    func timeoutDoesNotMatch() {
        #expect(SSHMatchExecutor.timeoutSeconds > 0)
        #expect(SSHMatchExecutor.timeoutSeconds < 6, "The connect path must stop a 6 second command")
        #expect(!SSHMatchExecutor.evaluate(command: "sleep 6", timeout: 0.1))
    }
}
