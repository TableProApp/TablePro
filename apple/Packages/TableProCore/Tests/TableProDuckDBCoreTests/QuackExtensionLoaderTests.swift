import Foundation
import TableProDuckDBCore
import Testing

private struct DuckDBText: Error, LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

// Measured with an empty extension directory and no route to the extension repository.
private let downloadFailed = "IO Error: Failed to download extension \"quack\" at URL "
    + "\"http://127.0.0.1:1/v2.0.0/osx_arm64/quack.duckdb_extension.gz\" (ERROR Could not establish connection)"
private let installItFirst = "IO Error: Extension \"/Users/me/.duckdb/extensions/v2.0.0/osx_arm64/quack.duckdb_extension\" "
    + "not found. Install it first using \"INSTALL quack\"."

/// Fails each statement with the next error queued for it, and runs it cleanly once the queue is empty.
private final class ScriptedDuckDB: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [String: [any Error]]
    private var statements: [String] = []

    init(failing failures: [String: [any Error]] = [:]) {
        self.failures = failures
    }

    var ran: [String] {
        lock.withLock { statements }
    }

    func execute(_ statement: String) throws {
        let failure = lock.withLock { () -> (any Error)? in
            statements.append(statement)
            guard var queued = failures[statement], !queued.isEmpty else { return nil }
            let failure = queued.removeFirst()
            failures[statement] = queued
            return failure
        }
        if let failure { throw failure }
    }
}

struct QuackExtensionLoaderTests {
    @Test("An installed extension is loaded with no INSTALL, so no network is needed")
    func loadsWithoutInstalling() async throws {
        let duckdb = ScriptedDuckDB()
        try await QuackExtensionLoader.load("quack") { try duckdb.execute($0) }
        #expect(duckdb.ran == ["LOAD quack"])
    }

    @Test("A failed LOAD installs, then loads again")
    func installsAfterAFailedLoad() async throws {
        let duckdb = ScriptedDuckDB(failing: ["LOAD quack": [DuckDBText(text: installItFirst)]])
        try await QuackExtensionLoader.load("quack") { try duckdb.execute($0) }
        #expect(duckdb.ran == ["LOAD quack", "INSTALL quack", "LOAD quack"])
    }

    @Test("When INSTALL and LOAD both fail, INSTALL's cause is reported, not LOAD's advice to install")
    func reportsTheInstallFailure() async throws {
        let duckdb = ScriptedDuckDB(failing: [
            "LOAD quack": [DuckDBText(text: installItFirst), DuckDBText(text: installItFirst)],
            "INSTALL quack": [DuckDBText(text: downloadFailed)]
        ])
        await #expect(throws: QuackConnectError.extensionNotInstalled(name: "quack", detail: downloadFailed)) {
            try await QuackExtensionLoader.load("quack") { try duckdb.execute($0) }
        }
        #expect(duckdb.ran == ["LOAD quack", "INSTALL quack", "LOAD quack"])
        let message = try #require(QuackConnectError.extensionNotInstalled(name: "quack", detail: downloadFailed).errorDescription)
        #expect(message.contains("Failed to download extension"))
        #expect(!message.contains("Install it first"))
    }

    @Test("When INSTALL works and LOAD still fails, the second LOAD's error is reported")
    func reportsTheLoadFailure() async {
        let duckdb = ScriptedDuckDB(failing: [
            "LOAD httpfs": [DuckDBText(text: "first"), DuckDBText(text: "IO Error: wrong platform")]
        ])
        await #expect(throws: QuackConnectError.extensionNotLoaded(name: "httpfs", detail: "IO Error: wrong platform")) {
            try await QuackExtensionLoader.load("httpfs") { try duckdb.execute($0) }
        }
        #expect(duckdb.ran == ["LOAD httpfs", "INSTALL httpfs", "LOAD httpfs"])
    }

    @Test("A cancelled connect stops at once and is rethrown as it is")
    func cancellationStops() async {
        let duckdb = ScriptedDuckDB(failing: ["LOAD quack": [CancellationError()]])
        await #expect(throws: CancellationError.self) {
            try await QuackExtensionLoader.load("quack") { try duckdb.execute($0) }
        }
        #expect(duckdb.ran == ["LOAD quack"])
    }
}
