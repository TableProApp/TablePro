//
//  ServerOutputCaptureTests.swift
//  TableProTests
//
//  The server hands printed lines to whoever asks next. These pin the read before every statement, which discards
//  what other work left, the read after it, the failed one included, and what a failure shows.
//

import Foundation
import os
@testable import TablePro
import TableProPluginKit
import Testing

struct ServerOutputCaptureTests {
    private struct StatementFailed: Error {}

    private static let printed = PluginServerOutput(lines: ["Hello from PL/SQL", ""], isTruncated: false)
    private static let leftOver = PluginServerOutput(lines: ["NOTICE:  audit row written"], isTruncated: false)

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
        #expect(driver.fetchServerOutputCallCount == 2)
    }

    @Test("A cancelled statement sends nothing more to the server after it")
    func cancellationReadsNothingAfter() async {
        let driver = MockDatabaseDriver()
        let box = ServerOutputBox()

        await #expect(throws: CancellationError.self) {
            _ = try await ServerOutputCapture.running(on: driver, failureOutput: box) { () throws -> QueryResult in
                throw CancellationError()
            }
        }
        #expect(driver.fetchServerOutputCallCount == 1)
    }

    @Test("What the session printed before the statement is not reported as its output")
    func earlierOutputIsDiscarded() async throws {
        let session = PrintingSession(printed: [Self.leftOver, Self.printed])

        let result = try await ServerOutputCapture.running(on: session.driver, failureOutput: ServerOutputBox()) {
            Self.result()
        }

        #expect(result.serverOutput == Self.printed)
        #expect(session.plugin.reads == 2)
    }

    @Test("A failure reports only what the failed statement printed")
    func failureDiscardsEarlierOutput() async {
        let session = PrintingSession(printed: [Self.leftOver, Self.printed])
        let box = ServerOutputBox()

        await #expect(throws: StatementFailed.self) {
            _ = try await ServerOutputCapture.running(on: session.driver, failureOutput: box) { () throws -> QueryResult in
                throw StatementFailed()
            }
        }
        #expect(box.output == Self.printed)
    }

    // Oracle dials a new session after a Stop closed the old one, so the statement would still run there.
    @Test("A Stop during the read before the statement runs no statement")
    func stopDuringTheEarlierReadRunsNothing() async {
        let session = PrintingSession(printed: [Self.leftOver])
        session.plugin.whileReading = { withUnsafeCurrentTask { $0?.cancel() } }
        let ran = OSAllocatedUnfairLock(initialState: false)

        let run = Task {
            try await ServerOutputCapture.running(on: session.driver, failureOutput: ServerOutputBox()) { () throws -> QueryResult in
                ran.withLock { $0 = true }
                return Self.result()
            }
        }

        await #expect(throws: CancellationError.self) { _ = try await run.value }
        #expect(ran.withLock { $0 } == false)
    }

    @Test("Appending keeps the lines in order and stays cut short once either part was")
    func appendingJoinsTheLines() {
        let first = PluginServerOutput(lines: ["step 1"], isTruncated: false)
        let later = PluginServerOutput(lines: ["checked 1", "checked 2"], isTruncated: true)

        #expect(first.appending(later) == PluginServerOutput(lines: ["step 1", "checked 1", "checked 2"], isTruncated: true))
        #expect(first.appending(.none) == first)
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

// Each read takes what the session printed since the last one, as a real session's output is consumed.
private struct PrintingSession {
    let plugin: SequencedOutputPlugin
    let driver: DatabaseDriver

    init(printed: [PluginServerOutput]) {
        plugin = SequencedOutputPlugin(printed: printed)
        driver = PluginDriverAdapter(connection: TestFixtures.makeConnection(), pluginDriver: plugin)
    }
}

private final class SequencedOutputPlugin: PluginDriverStub, @unchecked Sendable {
    private var printed: [PluginServerOutput]
    private(set) var reads = 0
    var whileReading: (() -> Void)?

    init(printed: [PluginServerOutput]) {
        self.printed = printed
    }

    func fetchServerOutput() async throws -> PluginServerOutput {
        reads += 1
        whileReading?()
        return printed.isEmpty ? .none : printed.removeFirst()
    }
}
