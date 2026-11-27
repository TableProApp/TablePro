//
//  PluginDriverAdapterIsolationTests.swift
//  TableProTests
//

import Foundation
import os
@testable import TablePro
import TableProPluginKit
import Testing

// The app builds with NonisolatedNonsendingByDefault, so the adapter's own work around a driver call (the statement's
// checks and description, the schema it reads, the mapping of the answer) ran on its caller's actor, the main one.
// PluginKit builds without it, so the call itself already left. "adapter" is where the adapter read the driver's state.
@MainActor
struct PluginDriverAdapterIsolationTests {
    private func makeAdapter(_ driver: ThreadRecordingDriver) -> PluginDriverAdapter {
        PluginDriverAdapter(connection: TestFixtures.makeConnection(type: .mysql), pluginDriver: driver)
    }

    @Test("A user query is checked, described and mapped off the main thread")
    func userQueryRunsOffMain() async throws {
        let driver = ThreadRecordingDriver()
        _ = try await makeAdapter(driver).executeUserQuery(query: "SELECT 1", rowCap: nil, parameters: nil)
        #expect(driver.calls() == ["adapter": false, "executeUserQuery": false])
    }

    @Test("A parameterized user query leaves the main thread once its parameters are converted")
    func parameterizedUserQueryRunsOffMain() async throws {
        let driver = ThreadRecordingDriver()
        _ = try await makeAdapter(driver).executeUserQuery(query: "SELECT ?", rowCap: 10, parameters: [1])
        #expect(driver.calls() == ["adapter": false, "executeUserQuery": false])
    }

    @Test("A bounded read and the streamed collect it awaits run off the main thread")
    func boundedQueryCollectsOffMain() async throws {
        let driver = ThreadRecordingDriver()
        let result = try await makeAdapter(driver).executeBoundedQuery(query: "SELECT 1", rowCap: 2)
        #expect(result?.rows.count == 2)
        #expect(driver.calls() == ["adapter": false, "executeBoundedQuery": false])
    }

    @Test("The query executor's fetch reaches the driver off the main thread")
    func queryExecutorFetchRunsOffMain() async throws {
        let driver = ThreadRecordingDriver()
        _ = try await QueryExecutor.fetchQueryData(driver: makeAdapter(driver), sql: "SELECT 1", rowCap: 2)
        #expect(driver.calls() == ["adapter": false, "executeBoundedQuery": false])
    }

    @Test("A catalog read runs off the main thread")
    func catalogReadRunsOffMain() async throws {
        let driver = ThreadRecordingDriver()
        _ = try await makeAdapter(driver).fetchColumns(table: "t", schema: nil)
        #expect(driver.calls() == ["adapter": false, "fetchColumns": false])
    }
}

// `Thread.isMainThread` is unavailable in an async context, and the question is asked from one on purpose.
private func isOnMainThread() -> Bool {
    pthread_main_np() != 0
}

private final class ThreadRecordingDriver: PluginDriverStub, @unchecked Sendable {
    private let recorded = OSAllocatedUnfairLock<[String: Bool]>(initialState: [:])

    func calls() -> [String: Bool] {
        recorded.withLock { $0 }
    }

    // Any read on the main thread sticks, so a later one off it cannot hide it.
    private func record(_ name: String) {
        let onMain = isOnMainThread()
        recorded.withLock { $0[name] = ($0[name] ?? false) || onMain }
    }

    // Read by the adapter only: `readSchema` and the statement's lexical description ask for these.
    var currentSchema: String? {
        record("adapter")
        return nil
    }

    var sessionLexicalState: PluginSessionLexicalState? {
        record("adapter")
        return nil
    }

    private static let result = PluginQueryResult(
        columns: ["a"], columnTypeNames: ["INTEGER"], rows: [[.text("1")]], rowsAffected: 0, executionTime: 0
    )

    func executeUserQuery(query: String, rowCap: Int?, parameters: [PluginCellValue]?) async throws -> PluginQueryResult {
        await Task.yield()
        record("executeUserQuery")
        return Self.result
    }

    func executeBoundedQuery(query: String, rowCap: Int) async throws -> PluginQueryResult? {
        let collected = try await boundedQueryFromStream(query: query, rowCap: rowCap)
        record("executeBoundedQuery")
        return collected
    }

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.header(PluginStreamHeader(columns: ["a"], columnTypeNames: ["INTEGER"])))
            continuation.yield(.rows([[.text("1")], [.text("2")], [.text("3")]]))
            continuation.finish()
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        await Task.yield()
        record("fetchColumns")
        return []
    }
}
