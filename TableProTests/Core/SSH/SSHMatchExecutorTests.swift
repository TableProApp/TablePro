//
//  SSHMatchExecutorTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("SSH Match exec")
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
        #expect(!SSHMatchExecutor.evaluate(command: "sleep 6"))
    }
}
