//
//  TableTransferSessionScopeTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

private struct InsertFailure: Error {}

private final class ScopedTransferDriver: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var isInTransaction = false
    private let header: [String]
    private let rows: [PluginRow]
    private let opensScope: Bool
    private let failsInserts: Bool
    private let onInsert: (@Sendable () async -> Void)?

    init(
        header: [String] = [],
        rows: [PluginRow] = [],
        opensScope: Bool = true,
        failsInserts: Bool = false,
        onInsert: (@Sendable () async -> Void)? = nil
    ) {
        self.header = header
        self.rows = rows
        self.opensScope = opensScope
        self.failsInserts = failsInserts
        self.onInsert = onInsert
    }

    var events: [String] { lock.withLock { log } }

    var supportsTransactions: Bool { true }

    private func record(_ event: String) {
        lock.withLock { log.append(event) }
    }

    func openSessionScope(for purpose: PluginSessionPurpose) async throws -> PluginSessionScope? {
        record("open \(purpose)")
        guard opensScope else { return nil }
        return PluginSessionScope(
            purpose: purpose, saved: [], applied: [PluginSessionSetting(name: "time_zone", value: "+00:00")])
    }

    func closeSessionScope(_ scope: PluginSessionScope) async throws {
        record("close \(scope.purpose)")
    }

    func sessionTransactionState() async -> PluginSessionTransactionState {
        let isOpen = lock.withLock { isInTransaction }
        return isOpen ? .inTransaction : .idle
    }

    func beginTransaction() async throws { recordTransaction("begin", isOpen: true) }
    func commitTransaction() async throws { recordTransaction("commit", isOpen: false) }
    func rollbackTransaction() async throws { recordTransaction("rollback", isOpen: false) }

    private func recordTransaction(_ event: String, isOpen: Bool) {
        lock.withLock {
            log.append(event)
            isInTransaction = isOpen
        }
    }

    func defaultExportQuery(table: String, schema: String?) -> String? {
        "SELECT * FROM \(table)"
    }

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        record("stream")
        let streamHeader = PluginStreamHeader(columns: header, columnTypeNames: header.map { _ in "TEXT" })
        let batch = rows
        return AsyncThrowingStream { continuation in
            continuation.yield(.header(streamHeader))
            continuation.yield(.rows(batch))
            continuation.finish()
        }
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        record("insert")
        await onInsert?()
        if failsInserts { throw InsertFailure() }
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }
}

@MainActor
struct TableTransferSessionScopeTests {
    private func adapter(_ driver: ScopedTransferDriver, type: DatabaseType) -> PluginDriverAdapter {
        PluginDriverAdapter(connection: DatabaseConnection(name: "Test", type: type), pluginDriver: driver)
    }

    private func makeSource() -> ScopedTransferDriver {
        ScopedTransferDriver(
            header: ["id", "born"],
            rows: [[.text("0"), .text("0000-00-00")], [.text("1"), .text("2020-00-15")]]
        )
    }

    private func makeRequest(
        from sourceType: DatabaseType,
        to destinationType: DatabaseType,
        petsScope: PluginExportRowScope = .unrestricted
    ) -> TableTransferService.Request {
        TableTransferService.Request(
            objects: [
                ExportObjectItem(name: "people", kind: .table, isSelected: true),
                ExportObjectItem(name: "pets", kind: .table, isSelected: true, rowScope: petsScope)
            ],
            sourceType: sourceType,
            destinationType: destinationType,
            columnMapping: [
                "people": ["id": "id", "born": "born"],
                "pets": ["id": "id", "born": "born"]
            ]
        )
    }

    /// Once around every table, so the destination's scope outlives each table's own transaction.
    @Test("A same-engine transfer reads under the source's scope and writes under the destination's")
    func sameEngineTransferPinsBothSessions() async throws {
        let source = makeSource()
        let destination = ScopedTransferDriver()
        let service = TableTransferService()

        try await service.transfer(
            request: makeRequest(from: .mysql, to: .mysql),
            sourceDriver: adapter(source, type: .mysql),
            destinationDriver: adapter(destination, type: .mysql)
        )

        #expect(service.state.transferredRows == 4)
        #expect(source.events == ["open verbatimRead", "stream", "stream", "close verbatimRead"])
        #expect(destination.events == [
            "open verbatimWrite",
            "begin", "insert", "commit",
            "begin", "insert", "commit",
            "close verbatimWrite"
        ])
    }

    @Test("A failed transfer still closes both scopes")
    func failedTransferClosesBothScopes() async {
        let source = makeSource()
        let destination = ScopedTransferDriver(failsInserts: true)

        await #expect(throws: TableTransferError.self) {
            try await TableTransferService().transfer(
                request: makeRequest(from: .mysql, to: .mysql),
                sourceDriver: adapter(source, type: .mysql),
                destinationDriver: adapter(destination, type: .mysql)
            )
        }

        #expect(source.events.first == "open verbatimRead")
        #expect(source.events.last == "close verbatimRead")
        #expect(destination.events.first == "open verbatimWrite")
        #expect(destination.events.last == "close verbatimWrite")
        #expect(destination.events.contains("rollback"))
    }

    @Test("A stopped transfer still closes both scopes")
    func stoppedTransferClosesBothScopes() async {
        let service = TableTransferService()
        let source = makeSource()
        let destination = ScopedTransferDriver(onInsert: { await service.cancel() })

        await #expect(throws: TableTransferError.self) {
            try await service.transfer(
                request: makeRequest(from: .mysql, to: .mysql),
                sourceDriver: adapter(source, type: .mysql),
                destinationDriver: adapter(destination, type: .mysql)
            )
        }

        #expect(source.events == ["open verbatimRead", "stream", "close verbatimRead"])
        #expect(destination.events == ["open verbatimWrite", "begin", "insert", "rollback", "close verbatimWrite"])
    }

    @Test("A transfer between engines opens no scope")
    func crossEngineTransferOpensNoScope() async throws {
        let source = makeSource()
        let destination = ScopedTransferDriver()

        try await TableTransferService().transfer(
            request: makeRequest(from: .postgresql, to: .mysql),
            sourceDriver: adapter(source, type: .postgresql),
            destinationDriver: adapter(destination, type: .mysql)
        )

        #expect(!source.events.contains { $0.hasPrefix("open") })
        #expect(!destination.events.contains { $0.hasPrefix("open") })
        #expect(destination.events.filter { $0 == "insert" }.count == 2)
    }

    /// One filtered table is enough: the scopes span every table of the transfer.
    @Test("A transfer with a row filter reads and writes on the sessions as they are")
    func filteredTransferOpensNoScope() async throws {
        let source = makeSource()
        let destination = ScopedTransferDriver()
        let service = TableTransferService()

        try await service.transfer(
            request: makeRequest(
                from: .mysql, to: .mysql, petsScope: PluginExportRowScope(filter: "born > NOW() - INTERVAL 1 DAY")
            ),
            sourceDriver: adapter(source, type: .mysql),
            destinationDriver: adapter(destination, type: .mysql)
        )

        #expect(service.state.transferredRows == 4)
        #expect(!source.events.contains { $0.hasPrefix("open") })
        #expect(!destination.events.contains { $0.hasPrefix("open") })
    }

    @Test("A transfer limited to some rows keeps the scopes")
    func limitedTransferKeepsScopes() async throws {
        let source = makeSource()
        let destination = ScopedTransferDriver()

        try await TableTransferService().transfer(
            request: makeRequest(from: .mysql, to: .mysql, petsScope: PluginExportRowScope(rowLimit: 1)),
            sourceDriver: adapter(source, type: .mysql),
            destinationDriver: adapter(destination, type: .mysql)
        )

        #expect(source.events.first == "open verbatimRead")
        #expect(source.events.last == "close verbatimRead")
        #expect(destination.events.first == "open verbatimWrite")
        #expect(destination.events.last == "close verbatimWrite")
    }

    @Test("A destination with no scope closes the source's and still transfers every row")
    func destinationWithoutScopeStillTransfers() async throws {
        let source = makeSource()
        let destination = ScopedTransferDriver(opensScope: false)
        let service = TableTransferService()

        try await service.transfer(
            request: makeRequest(from: .mysql, to: .mysql),
            sourceDriver: adapter(source, type: .mysql),
            destinationDriver: adapter(destination, type: .mysql)
        )

        #expect(service.state.transferredRows == 4)
        #expect(source.events == ["open verbatimRead", "close verbatimRead", "stream", "stream"])
        #expect(destination.events.first == "open verbatimWrite")
        #expect(!destination.events.contains("close verbatimWrite"))
    }
}
