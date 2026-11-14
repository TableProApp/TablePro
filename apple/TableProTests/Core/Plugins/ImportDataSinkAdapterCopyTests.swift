//
//  ImportDataSinkAdapterCopyTests.swift
//  TableProTests
//

import Foundation
import os
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

private final class CopyingDriver: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private let declaresCopy: Bool
    private var copies: [(statement: String, data: Data)] = []

    init(declaresCopy: Bool) {
        self.declaresCopy = declaresCopy
    }

    var capabilities: PluginCapabilities {
        declaresCopy ? [.transactions, .copyFromStandardInput] : [.transactions]
    }

    var received: [(statement: String, data: Data)] {
        lock.withLock { copies }
    }

    func copyFromStandardInput(
        statement: String,
        rows: PluginCopyData,
        context: PluginStatementContext
    ) async throws -> PluginQueryResult {
        var data = Data()
        while let piece = try rows.nextPiece() {
            data.append(piece)
        }
        lock.withLock { copies.append((statement, data)) }
        return .empty
    }
}

// Reads the first piece, then holds the copy until a Stop cancels the query, as a copy waiting on its server does.
private final class StoppableCopyDriver: PluginDriverStub, @unchecked Sendable {
    let started = AsyncGate()
    private let stopped = AsyncGate()
    private let lock = NSLock()
    private var cancels = 0

    var capabilities: PluginCapabilities { [.transactions, .copyFromStandardInput] }

    var cancelCount: Int { lock.withLock { cancels } }

    func cancelQuery() throws {
        lock.withLock { cancels += 1 }
        Task { await stopped.open() }
    }

    func copyFromStandardInput(
        statement: String,
        rows: PluginCopyData,
        context: PluginStatementContext
    ) async throws -> PluginQueryResult {
        _ = try rows.nextPiece()
        await started.open()
        await stopped.wait()
        throw CancellationError()
    }
}

struct ImportDataSinkAdapterCopyTests {
    private static func rows(_ text: String) -> PluginCopyData {
        let remaining = OSAllocatedUnfairLock<Data?>(initialState: Data(text.utf8))
        return PluginCopyData {
            remaining.withLock { data in
                defer { data = nil }
                return data
            }
        }
    }

    private static func sink(on driver: CopyingDriver) -> ImportDataSinkAdapter {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: driver)
        return ImportDataSinkAdapter(driver: adapter, databaseType: .postgresql)
    }

    @Test("A COPY reaches a driver that declares copy-in with its header and every row byte")
    func copyReachesTheDriver() async throws {
        let driver = CopyingDriver(declaresCopy: true)
        let sink = Self.sink(on: driver)

        try await sink.copyFromStandardInput(statement: "COPY t (a) FROM stdin", line: 4, rows: Self.rows("1\n2\n"))

        let received = driver.received
        #expect(received.map { $0.statement } == ["COPY t (a) FROM stdin"])
        #expect(received.map { $0.data } == [Data("1\n2\n".utf8)])
    }

    @Test("A driver without copy-in refuses the COPY at its line before anything is sent")
    func driverWithoutCopyRefuses() async throws {
        let driver = CopyingDriver(declaresCopy: false)
        let sink = Self.sink(on: driver)

        await #expect(throws: SQLFileParseError.copyFromStandardInput(line: 4)) {
            try await sink.copyFromStandardInput(statement: "COPY t (a) FROM stdin", line: 4, rows: Self.rows("1\n"))
        }
        #expect(driver.received.isEmpty)
    }

    @Test("Stop during an import's COPY cancels the driver's copy at once and stops the run with rollback")
    func stopCancelsTheCopy() async throws {
        let driver = StoppableCopyDriver()
        let run = ImportRun()
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let sink = ImportDataSinkAdapter(
            driver: PluginDriverAdapter(connection: connection, pluginDriver: driver),
            databaseType: .postgresql,
            importRun: run
        )
        let copy = Task {
            try await sink.copyFromStandardInput(statement: "COPY t (a) FROM stdin", line: 1, rows: Self.rows("1\n"))
        }
        await driver.started.wait()

        run.requestPause()

        #expect(driver.cancelCount == 1)
        #expect(run.stopChoice == .rollBack)
        await #expect(throws: CancellationError.self) { try await copy.value }
        #expect(run.questionIfPaused() == nil)
    }
}
