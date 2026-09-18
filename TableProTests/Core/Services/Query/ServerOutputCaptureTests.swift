//
//  ServerOutputCaptureTests.swift
//  TableProTests
//
//  The server hands printed lines to whoever asks next, so output a statement left unread is reported under the one
//  after it. These pin the read after every statement, the failed one included, and what a failure shows.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Server output capture")
struct ServerOutputCaptureTests {
    private struct StatementFailed: Error {}

    private static let printed = PluginServerOutput(lines: ["Hello from PL/SQL", ""], isTruncated: false)

    private static func result() -> QueryResult {
        QueryResult(columns: [], columnTypes: [], rows: [], rowsAffected: 0, executionTime: 0, error: nil)
    }

    @Test("A statement that succeeds carries what it printed")
    func successCarriesTheOutput() async throws {
        let driver = MockDatabaseDriver()
        driver.serverOutputToReturn = Self.printed
        let box = ServerOutputBox()

        let result = try await ServerOutputCapture.running(on: driver, failureOutput: box) { Self.result() }

        #expect(result.serverOutput == Self.printed)
        #expect(box.output == .none)
    }

    @Test("A statement that fails still has its output read, for the failure to report")
    func failureStillReadsTheOutput() async {
        let driver = MockDatabaseDriver()
        driver.serverOutputToReturn = Self.printed
        let box = ServerOutputBox()

        await #expect(throws: StatementFailed.self) {
            _ = try await ServerOutputCapture.running(on: driver, failureOutput: box) { () throws -> QueryResult in
                throw StatementFailed()
            }
        }
        #expect(box.output == Self.printed)
        #expect(driver.fetchServerOutputCallCount == 1)
    }

    @Test("A cancelled statement sends nothing more to the server")
    func cancellationReadsNothing() async {
        let driver = MockDatabaseDriver()
        let box = ServerOutputBox()

        await #expect(throws: CancellationError.self) {
            _ = try await ServerOutputCapture.running(on: driver, failureOutput: box) { () throws -> QueryResult in
                throw CancellationError()
            }
        }
        #expect(driver.fetchServerOutputCallCount == 0)
    }

    @Test("A failure lists what the statement printed before it failed")
    func failureMessageListsTheOutput() {
        let message = ServerOutputCapture.failureMessage(
            "ORA-20001: boom",
            output: PluginServerOutput(lines: ["step 1", "step 2"], isTruncated: false)
        )
        #expect(message == ["ORA-20001: boom", String(localized: "Output before the error:"), "step 1", "step 2"]
            .joined(separator: "\n"))
        #expect(ServerOutputCapture.failureMessage("ORA-20001: boom", output: .none) == "ORA-20001: boom")
    }

    /// The message is laid out as text in the error banner and sent to Fix with AI whole, so a loop that printed
    /// thousands of long lines before failing must not come along with it.
    @Test("A failure's message carries only the first lines, each clipped")
    func failureMessageIsBounded() {
        let long = String(repeating: "x", count: 5_000)
        let output = PluginServerOutput(lines: Array(repeating: long, count: 1_000), isTruncated: true)
        let lines = ServerOutputCapture.failureMessage("ORA-20001: boom", output: output)
            .components(separatedBy: "\n")

        #expect(lines.count == 2 + ServerOutputCapture.failureLineLimit + 1)
        #expect(lines.dropFirst(2).prefix(ServerOutputCapture.failureLineLimit).allSatisfy {
            ($0 as NSString).length == ServerOutputCapture.failureLineLength + 1
        })
    }
}
