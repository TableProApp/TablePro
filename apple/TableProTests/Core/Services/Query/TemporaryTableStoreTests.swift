//
//  TemporaryTableStoreTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProSQLGrammar
import TableProTestSupport
import Testing

@MainActor
private final class FakeSessionReader: TemporaryTableSessionReading {
    final class Session {}

    let connectionId = UUID()
    var browseDatabase = "shop"
    var browseSchema: String?
    var session: Session? = Session()
    var answers: [Result<[TableInfo], Error>] = []
    var gate: AsyncGate?
    private(set) var reads = 0
    private(set) var finishedReads = 0

    func browseScope(for connectionId: UUID) -> DatabaseScope? {
        guard connectionId == self.connectionId else { return nil }
        return DatabaseScope(connectionId: connectionId, database: browseDatabase, schema: browseSchema)
    }

    func temporaryTableSession(for scope: DatabaseScope) -> ObjectIdentifier? {
        session.map { ObjectIdentifier($0) }
    }

    func readTemporaryTables(in scope: DatabaseScope) async throws -> TemporaryTableListing {
        guard let session else { throw DatabaseError.notConnected }
        let identity = ObjectIdentifier(session)
        reads += 1
        let answer = answers.isEmpty ? .success([]) : answers.removeFirst()
        if let gate { await gate.wait() }
        finishedReads += 1
        return TemporaryTableListing(tables: try answer.get(), session: identity)
    }
}

private struct ReadRefused: Error {}

@MainActor
struct TemporaryTableStoreTests {
    private static func table(_ name: String, schema: String? = nil) -> TableInfo {
        TableInfo(name: name, type: .table, rowCount: nil, schema: schema)
    }

    private static func loaded(_ answers: [Result<[TableInfo], Error>]) async -> (TemporaryTableStore, FakeSessionReader) {
        let reader = FakeSessionReader()
        reader.answers = answers
        let store = TemporaryTableStore(reader: { reader })
        store.refresh(connectionId: reader.connectionId)
        await store.waitUntilIdle(connectionId: reader.connectionId)
        return (store, reader)
    }

    @Test("A refresh lists the session's temporary tables under the browsed database")
    func refreshListsTheBrowsedDatabase() async {
        let (store, reader) = await Self.loaded([.success([Self.table("t")])])

        #expect(store.tables(connectionId: reader.connectionId, database: "shop").map { $0.name } == ["t"])
        #expect(store.tables(connectionId: reader.connectionId, database: "other").isEmpty)
    }

    @Test("A listing read on a connection that has since been replaced is not shown")
    func replacedSessionHidesItsListing() async {
        let (store, reader) = await Self.loaded([.success([Self.table("t")])])

        reader.session = FakeSessionReader.Session()

        #expect(store.tables(connectionId: reader.connectionId, database: "shop").isEmpty)
        #expect(!store.holds(table: "t", in: DatabaseScope(connectionId: reader.connectionId, database: "shop", schema: nil)))
    }

    @Test("A failed read keeps the list it had")
    func failedReadKeepsTheListing() async {
        let (store, reader) = await Self.loaded([.success([Self.table("t")]), .failure(ReadRefused())])

        store.refresh(connectionId: reader.connectionId)
        await store.waitUntilIdle(connectionId: reader.connectionId)

        #expect(reader.reads == 2)
        #expect(store.tables(connectionId: reader.connectionId, database: "shop").map { $0.name } == ["t"])
    }

    @Test("A table listed with a schema holds only scopes on that schema; one listed without holds the bare name")
    func holdsMatchesTheSchemaTheListingNames() async {
        let (store, reader) = await Self.loaded([.success([Self.table("t", schema: "pg_temp_3"), Self.table("#scratch")])])
        func scope(_ schema: String?) -> DatabaseScope {
            DatabaseScope(connectionId: reader.connectionId, database: "shop", schema: schema)
        }

        #expect(store.holds(table: "t", in: scope("pg_temp_3")))
        #expect(!store.holds(table: "t", in: scope("public")))
        #expect(store.holds(table: "#scratch", in: scope("dbo")))
        #expect(!store.holds(table: "other", in: scope(nil)))
    }

    @Test("A refresh asked for during a read reads once more after it")
    func refreshDuringAReadRunsAgain() async throws {
        let reader = FakeSessionReader()
        let gate = AsyncGate()
        reader.gate = gate
        reader.answers = [.success([]), .success([Self.table("t")])]
        let store = TemporaryTableStore(reader: { reader })

        store.refresh(connectionId: reader.connectionId)
        await gate.arrived(1)
        store.refresh(connectionId: reader.connectionId)
        await gate.open()
        await store.waitUntilIdle(connectionId: reader.connectionId)

        #expect(reader.reads == 2)
        #expect(store.tables(connectionId: reader.connectionId, database: "shop").map { $0.name } == ["t"])
    }

    @Test("A read that lands after the connection closed writes nothing")
    func lateReadAfterDisconnectIsDropped() async throws {
        let reader = FakeSessionReader()
        let gate = AsyncGate()
        reader.gate = gate
        reader.answers = [.success([Self.table("t")])]
        let store = TemporaryTableStore(reader: { reader })

        store.refresh(connectionId: reader.connectionId)
        await gate.arrived(1)
        store.removeConnection(reader.connectionId)
        await gate.open()
        try await waitUntil { reader.finishedReads == 1 }

        #expect(store.listings.isEmpty)
    }

    @Test("Only a change that can touch tables refreshes the list")
    func onlyTableChangesRefresh() async {
        let reader = FakeSessionReader()
        let store = TemporaryTableStore(reader: { reader })

        await store.refreshCatalog(for: CatalogChange(connectionId: reader.connectionId, kinds: .routines))
        await store.waitUntilIdle(connectionId: reader.connectionId)
        #expect(reader.reads == 0)

        await store.refreshCatalog(for: CatalogChange(connectionId: reader.connectionId, kinds: .tables))
        await store.waitUntilIdle(connectionId: reader.connectionId)
        #expect(reader.reads == 1)
    }

    @Test("An engine that cannot list temporary tables is never read")
    func engineWithoutListingIsNotRead() async {
        let reader = FakeSessionReader()
        reader.session = nil
        let store = TemporaryTableStore(reader: { reader })

        store.refresh(connectionId: reader.connectionId)
        await store.waitUntilIdle(connectionId: reader.connectionId)

        #expect(reader.reads == 0)
    }
}
