import Foundation
import os
@testable import TablePro
import Testing

@MainActor
struct TableHealthHistoryStorageTests {
    private typealias Fixture = TableHealthFixture

    private struct Change: Hashable, Sendable {
        let connectionId: UUID
        let database: String
    }

    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("TableHealthHistoryStorageTests-\(UUID().uuidString)", isDirectory: true)
    private let connectionId = UUID()
    private let notifications = NotificationCenter()

    private let orders = Fixture.finding(table: "orders")
    private let ordersNoteIndex = Fixture.finding(.unusedIndex, table: "orders", object: "orders_note_idx")
    private let invoices = Fixture.finding(table: "invoices")
    private let billingOrders = Fixture.finding(schema: "billing", table: "orders")

    private static func day(_ number: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(number) * 86_400)
    }

    private func makeStore() -> TableHealthHistoryStorage {
        TableHealthHistoryStorage(directory: directory, notificationCenter: notifications)
    }

    private var fileURL: URL {
        directory.appendingPathComponent("\(connectionId.uuidString).json")
    }

    private func corruptFileURL(_ number: Int) -> URL {
        directory.appendingPathComponent("\(connectionId.uuidString).corrupt-\(number).json")
    }

    private func report(_ findings: [TableHealthFinding]) -> TableHealthReport {
        Fixture.report([
            (.missingPrimaryKey, .completed, findings.filter { $0.kind == .missingPrimaryKey }),
            (.unusedIndex, .completed, findings.filter { $0.kind == .unusedIndex })
        ])
    }

    private func id(
        _ kind: TableHealthCheckKind = .missingPrimaryKey,
        schema: String? = "public",
        table: String,
        object: String? = nil
    ) -> TableHealthFindingID {
        TableHealthFindingID(kind: kind, schema: schema, table: table, object: object)
    }

    private func scope(_ table: String, database: String = "shop", schema: String? = "public") -> TableScope {
        TableScope(connectionId: connectionId, database: database, schema: schema, table: table)
    }

    // Records orders, its note index and billing.orders, then ignores orders.
    private func seededStore() throws -> TableHealthHistoryStorage {
        let store = makeStore()
        _ = try store.record(
            report([orders, ordersNoteIndex, billingOrders]),
            connectionId: connectionId,
            database: "shop",
            at: Self.day(1)
        )
        _ = try store.setIgnored([orders.id], ignored: true, connectionId: connectionId, database: "shop", at: Self.day(1))
        return store
    }

    private func changes(during body: () throws -> Void) rethrows -> [Change] {
        let received = OSAllocatedUnfairLock(initialState: [Change]())
        let observer = notifications.addObserver(forName: .tableHealthHistoryDidChange, object: nil, queue: nil) { note in
            guard let scope = TableHealthHistoryChange.scope(of: note) else { return }
            received.withLock { $0.append(Change(connectionId: scope.connectionId, database: scope.database)) }
        }
        defer { notifications.removeObserver(observer) }
        try body()
        return received.withLock { $0 }
    }

    @Test("A recorded run reads back from disk in a new store")
    func recordedRunReadsBack() throws {
        let saved = try makeStore().record(report([orders]), connectionId: connectionId, database: "shop", at: Self.day(1))

        let reread = try makeStore().ledger(connectionId: connectionId, database: "shop")

        #expect(reread == saved)
        #expect(reread.runIndex == 1)
        #expect(reread.firstSeen(orders.id) == Self.day(1))
    }

    @Test("Each database keeps its own ledger inside the connection's one file")
    func databasesShareOneFile() throws {
        let store = makeStore()
        _ = try store.record(report([orders]), connectionId: connectionId, database: "shop", at: Self.day(1))
        _ = try store.record(report([invoices]), connectionId: connectionId, database: "analytics", at: Self.day(2))

        let shop = try store.ledger(connectionId: connectionId, database: "shop")
        let analytics = try store.ledger(connectionId: connectionId, database: "analytics")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)

        #expect(shop.firstSeen(orders.id) == Self.day(1))
        #expect(shop.firstSeen(invoices.id) == nil)
        #expect(analytics.firstSeen(invoices.id) == Self.day(2))
        #expect(analytics.firstSeen(orders.id) == nil)
        #expect(files == ["\(connectionId.uuidString).json"])
    }

    @Test("A database with no history reads as an empty ledger and leaves no file")
    func missingHistoryIsEmpty() throws {
        let ledger = try makeStore().ledger(connectionId: connectionId, database: "shop")

        #expect(ledger == TableHealthLedger())
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("Every write posts the connection and database it changed")
    func writesPostTheirScope() throws {
        let store = makeStore()

        let posted = try changes {
            _ = try store.record(report([orders]), connectionId: connectionId, database: "shop", at: Self.day(1))
            _ = try store.setIgnored([orders.id], ignored: true, connectionId: connectionId, database: "shop", at: Self.day(1))
        }

        #expect(posted == [
            Change(connectionId: connectionId, database: "shop"),
            Change(connectionId: connectionId, database: "shop")
        ])
    }

    @Test("A change that leaves the ledger as it was writes nothing and posts nothing")
    func noOpChangeWritesNothing() throws {
        let store = makeStore()

        let posted = try changes {
            _ = try store.clearResolved(connectionId: connectionId, database: "shop")
            _ = try store.setIgnored([orders.id], ignored: false, connectionId: connectionId, database: "shop", at: Self.day(1))
        }

        #expect(posted.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("Ignoring and stopping ignoring both persist")
    func ignorePersists() throws {
        let store = try seededStore()
        #expect(try makeStore().ledger(connectionId: connectionId, database: "shop").isIgnored(orders.id))

        _ = try store.setIgnored([orders.id], ignored: false, connectionId: connectionId, database: "shop", at: Self.day(2))

        let reread = try makeStore().ledger(connectionId: connectionId, database: "shop")
        #expect(!reread.isIgnored(orders.id))
    }

    @Test("Clear Resolved forgets resolved findings and keeps the open ones")
    func clearResolvedPersists() throws {
        let store = makeStore()
        _ = try store.record(report([orders, invoices]), connectionId: connectionId, database: "shop", at: Self.day(1))
        let resolvedRun = try store.record(report([orders]), connectionId: connectionId, database: "shop", at: Self.day(2))
        let resolvedIds = resolvedRun.resolved.map { $0.id }
        #expect(resolvedIds == [invoices.id])

        _ = try store.clearResolved(connectionId: connectionId, database: "shop")

        let reread = try makeStore().ledger(connectionId: connectionId, database: "shop")
        #expect(reread.resolved.isEmpty)
        #expect(reread.firstSeen(orders.id) == Self.day(1))
    }

    @Test("An unreadable file is set aside under a free name and never written over")
    func unreadableFileIsSetAside() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("older copy".utf8).write(to: corruptFileURL(1))
        try Data("{ not json".utf8).write(to: fileURL)
        let store = makeStore()

        #expect(try store.ledger(connectionId: connectionId, database: "shop") == TableHealthLedger())
        #expect(try String(contentsOf: corruptFileURL(1), encoding: .utf8) == "older copy")
        #expect(try String(contentsOf: corruptFileURL(2), encoding: .utf8) == "{ not json")

        _ = try store.record(report([orders]), connectionId: connectionId, database: "shop", at: Self.day(1))

        #expect(try makeStore().ledger(connectionId: connectionId, database: "shop").firstSeen(orders.id) == Self.day(1))
        #expect(try String(contentsOf: corruptFileURL(2), encoding: .utf8) == "{ not json")
    }

    @Test("A write that cannot land throws and posts nothing")
    func failedWriteThrows() throws {
        // A file where the folder should be, so the folder cannot be made.
        try Data().write(to: URL(fileURLWithPath: directory.path, isDirectory: false))
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore()
        var thrown: (any Error)?

        let posted = changes {
            do {
                _ = try store.record(report([orders]), connectionId: connectionId, database: "shop", at: Self.day(1))
            } catch {
                thrown = error
            }
        }

        #expect(thrown is TableHealthHistoryStorageError)
        #expect(posted.isEmpty)
    }

    @Test("A renamed table keeps its findings, their dates and its ignore mark")
    func renameTableMovesEntries() throws {
        let store = try seededStore()

        store.renameTable(from: scope("orders"), to: scope("purchases"))

        let ledger = try store.ledger(connectionId: connectionId, database: "shop")
        #expect(ledger.isIgnored(id(table: "purchases")))
        #expect(ledger.firstSeen(id(table: "purchases")) == Self.day(1))
        #expect(ledger.firstSeen(id(.unusedIndex, table: "purchases", object: "orders_note_idx")) == Self.day(1))
        #expect(ledger.firstSeen(orders.id) == nil)
        #expect(ledger.firstSeen(billingOrders.id) == Self.day(1))
    }

    @Test("A table on an engine without schemas, MySQL, follows its rename")
    func renameSchemalessTable() throws {
        let store = makeStore()
        let mysqlOrders = Fixture.finding(schema: nil, table: "orders")
        _ = try store.record(report([mysqlOrders]), connectionId: connectionId, database: "shop", at: Self.day(1))

        store.renameTable(from: scope("orders", schema: nil), to: scope("purchases", schema: nil))

        let ledger = try store.ledger(connectionId: connectionId, database: "shop")
        #expect(ledger.firstSeen(id(schema: nil, table: "purchases")) == Self.day(1))
        #expect(ledger.firstSeen(mysqlOrders.id) == nil)
    }

    @Test("A renamed schema takes its findings along and leaves other schemas alone")
    func renameSchemaMovesEntries() throws {
        let store = try seededStore()

        store.renameContainer(
            connectionId: connectionId, fromDatabase: "shop", fromSchema: "billing", toDatabase: "shop", toSchema: "finance"
        )

        let ledger = try store.ledger(connectionId: connectionId, database: "shop")
        #expect(ledger.firstSeen(id(schema: "finance", table: "orders")) == Self.day(1))
        #expect(ledger.firstSeen(billingOrders.id) == nil)
        #expect(ledger.isIgnored(orders.id))
    }

    @Test("A renamed database takes its whole ledger along")
    func renameDatabaseMovesLedger() throws {
        let store = try seededStore()
        let before = try store.ledger(connectionId: connectionId, database: "shop")

        let posted = changes {
            store.renameContainer(
                connectionId: connectionId, fromDatabase: "shop", fromSchema: nil, toDatabase: "store", toSchema: nil
            )
        }

        #expect(try store.ledger(connectionId: connectionId, database: "store") == before)
        #expect(try store.ledger(connectionId: connectionId, database: "shop") == TableHealthLedger())
        #expect(Set(posted) == [
            Change(connectionId: connectionId, database: "shop"),
            Change(connectionId: connectionId, database: "store")
        ])
    }

    @Test("A dropped table forgets its findings and ignore marks, and only its own")
    func dropTableForgetsEntries() throws {
        let store = try seededStore()

        store.dropTable(scope("orders"))

        let ledger = try store.ledger(connectionId: connectionId, database: "shop")
        #expect(ledger.firstSeen(orders.id) == nil)
        #expect(ledger.firstSeen(ordersNoteIndex.id) == nil)
        #expect(!ledger.isIgnored(orders.id))
        #expect(ledger.firstSeen(billingOrders.id) == Self.day(1))
    }

    @Test("A dropped schema forgets its findings and leaves other schemas alone")
    func dropSchemaForgetsEntries() throws {
        let store = try seededStore()

        store.dropContainer(connectionId: connectionId, database: "shop", schema: "billing")

        let ledger = try store.ledger(connectionId: connectionId, database: "shop")
        #expect(ledger.firstSeen(billingOrders.id) == nil)
        #expect(ledger.firstSeen(orders.id) == Self.day(1))
    }

    @Test("A dropped database forgets its ledger, and the file goes with the last one")
    func dropDatabaseForgetsLedger() throws {
        let store = try seededStore()
        _ = try store.record(report([invoices]), connectionId: connectionId, database: "analytics", at: Self.day(1))

        store.dropContainer(connectionId: connectionId, database: "shop", schema: nil)

        #expect(try store.ledger(connectionId: connectionId, database: "shop") == TableHealthLedger())
        #expect(try store.ledger(connectionId: connectionId, database: "analytics").firstSeen(invoices.id) == Self.day(1))

        store.dropContainer(connectionId: connectionId, database: "analytics", schema: nil)

        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("Deleting a connection removes its history and set-aside copies, and no other connection's")
    func purgeRemovesConnectionFiles() throws {
        let store = try seededStore()
        try Data("{ not json".utf8).write(to: corruptFileURL(1))
        let otherConnection = UUID()
        _ = try store.record(report([orders]), connectionId: otherConnection, database: "shop", at: Self.day(1))

        store.purgeConnections([connectionId], leavesTombstones: true)

        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: corruptFileURL(1).path))
        #expect(try store.ledger(connectionId: otherConnection, database: "shop").firstSeen(orders.id) == Self.day(1))
    }

    @Test("Deleting a connection reaches the history store through the registry")
    func registryHoldsTheStore() {
        let shared = TableHealthHistoryStorage.shared
        let registered = TableScopedSettingsRegistry.stores.contains { $0 === shared }
        #expect(registered)
    }
}
