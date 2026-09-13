//
//  CatalogChangeServiceTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
private final class RecordingCatalogTarget: CatalogChangeTarget {
    private(set) var changes: [CatalogChange] = []
    private var gate: CheckedContinuation<Void, Never>?
    var pausesFirstRefresh = false
    var onPaused: (@MainActor () -> Void)?

    func refreshCatalog(for change: CatalogChange) async {
        changes.append(change)
        guard pausesFirstRefresh else { return }
        pausesFirstRefresh = false
        await withCheckedContinuation { continuation in
            gate = continuation
            onPaused?()
        }
    }

    func resume() {
        gate?.resume()
        gate = nil
    }
}

@MainActor
private final class OrderLog {
    private(set) var entries: [String] = []

    func append(_ entry: String) {
        entries.append(entry)
    }
}

@MainActor
private final class OrderedCatalogTarget: CatalogChangeTarget {
    let name: String
    let leads: Bool
    let log: OrderLog

    init(name: String, leads: Bool, log: OrderLog) {
        self.name = name
        self.leads = leads
        self.log = log
    }

    func refreshesBeforeOtherTargets(for change: CatalogChange) -> Bool {
        leads
    }

    func refreshCatalog(for change: CatalogChange) async {
        log.append("\(name) start")
        await Task.yield()
        log.append("\(name) end")
    }
}

@Suite("CatalogChange")
struct CatalogChangeTests {
    @Test("an empty database or schema reaches everything")
    func emptyScopeIsConnectionWide() {
        let change = CatalogChange(connectionId: UUID(), database: "", schema: "public", kinds: .tables)
        #expect(change.database == nil)
        #expect(change.schema == nil)
        #expect(change.reaches(database: "anything", schema: "anything"))
    }

    @Test("a scoped change reaches only its database and schema")
    func scopedChangeReachesItsScope() {
        let change = CatalogChange(connectionId: UUID(), database: "shop", schema: "public", kinds: .tables)
        #expect(change.reaches(database: "shop", schema: "public"))
        #expect(!change.reaches(database: "shop", schema: "billing"))
        #expect(!change.reaches(database: "warehouse", schema: "public"))
        #expect(change.reaches(database: "shop"))
    }

    @Test("merging keeps the shared scope and unions the kinds")
    func mergingWidensToWhatBothReach() {
        let connectionId = UUID()
        let tables = CatalogChange(connectionId: connectionId, database: "shop", schema: "public", kinds: .tables)
        let routines = CatalogChange(connectionId: connectionId, database: "shop", schema: "billing", kinds: .routines)
        let elsewhere = CatalogChange(connectionId: connectionId, database: "warehouse", kinds: .types)

        let sameDatabase = tables.merging(routines)
        #expect(sameDatabase.database == "shop")
        #expect(sameDatabase.schema == nil)
        #expect(sameDatabase.kinds == [.tables, .routines])

        let differentDatabase = sameDatabase.merging(elsewhere)
        #expect(differentDatabase.database == nil)
        #expect(differentDatabase.kinds == [.tables, .routines, .types])
    }
}

@Suite("CatalogChangeService")
@MainActor
struct CatalogChangeServiceTests {
    private func makeService(
        target: RecordingCatalogTarget,
        isLive: @escaping @MainActor (UUID) -> Bool = { _ in true }
    ) -> CatalogChangeService {
        CatalogChangeService(targets: [target], isSessionLive: isLive)
    }

    @Test("changes are accepted while connected or switching databases, and dropped otherwise")
    func sessionAcceptanceFollowsStatusAndLiveness() {
        let connection = TestFixtures.makeConnection()
        var session = ConnectionSession(connection: connection, driver: MockDatabaseDriver(connection: connection))

        session.status = .connected
        #expect(CatalogChangeService.acceptsChanges(from: session))
        session.status = .connecting
        #expect(CatalogChangeService.acceptsChanges(from: session))
        session.status = .disconnected
        #expect(!CatalogChangeService.acceptsChanges(from: session))
        session.status = .error("gone")
        #expect(!CatalogChangeService.acceptsChanges(from: session))

        session.status = .connected
        session.liveness = .unreachable(nil)
        #expect(!CatalogChangeService.acceptsChanges(from: session))

        session.liveness = .live
        session.driver = nil
        #expect(!CatalogChangeService.acceptsChanges(from: session))
    }

    @Test("a statement that changes the catalog refreshes it connection-wide")
    func definitionStatementRefreshes() async {
        let target = RecordingCatalogTarget()
        let service = makeService(target: target)
        let connectionId = UUID()

        service.record(.statementsRan(
            connectionId: connectionId, statements: ["DROP TABLE sidebar_probe"], databaseType: .mysql
        ))
        await service.waitUntilIdle(connectionId: connectionId)

        #expect(target.changes == [CatalogChange(connectionId: connectionId, kinds: .tables)])
    }

    @Test("a statement that cannot change the catalog refreshes nothing")
    func readStatementDoesNothing() async {
        let target = RecordingCatalogTarget()
        let service = makeService(target: target)
        let connectionId = UUID()

        service.record(.statementsRan(connectionId: connectionId, statements: ["SELECT 1"], databaseType: .mysql))
        await service.waitUntilIdle(connectionId: connectionId)

        #expect(target.changes.isEmpty)
    }

    @Test("a connection that is not live records nothing")
    func deadSessionIsIgnored() async {
        let target = RecordingCatalogTarget()
        let service = makeService(target: target, isLive: { _ in false })
        let connectionId = UUID()

        service.record(.changed(CatalogChange(connectionId: connectionId, kinds: .everything)))
        await service.waitUntilIdle(connectionId: connectionId)

        #expect(target.changes.isEmpty)
    }

    @Test("changes arriving during a refresh merge into one more run")
    func burstCoalescesIntoOneTrailingRun() async {
        let target = RecordingCatalogTarget()
        target.pausesFirstRefresh = true
        let service = makeService(target: target)
        let connectionId = UUID()
        let paused = AsyncStream.makeStream(of: Void.self)
        target.onPaused = { paused.continuation.yield() }

        service.record(.changed(CatalogChange(connectionId: connectionId, database: "shop", kinds: .tables)))
        for await _ in paused.stream { break }
        for index in 0..<50 {
            service.record(.changed(
                CatalogChange(connectionId: connectionId, database: "shop", kinds: index.isMultiple(of: 2) ? .tables : .routines)
            ))
        }
        target.resume()
        await service.waitUntilIdle(connectionId: connectionId)

        #expect(target.changes.count == 2)
        #expect(target.changes.last == CatalogChange(connectionId: connectionId, database: "shop", kinds: [.tables, .routines]))
    }

    @Test("every transaction end refreshes objects and schemas, whichever driver ran the change")
    func transactionEndRefreshesObjectsAndSchemas() async {
        let target = RecordingCatalogTarget()
        let service = makeService(target: target)
        let connectionId = UUID()

        service.record(.transactionEnded(connectionId: connectionId))
        await service.waitUntilIdle(connectionId: connectionId)
        service.record(.statementsRan(connectionId: connectionId, statements: ["COMMIT"], databaseType: .postgresql))
        await service.waitUntilIdle(connectionId: connectionId)

        #expect(target.changes.map(\.kinds) == [[.objects, .schemas], [.objects, .schemas]])
    }

    @Test("rolling back to a savepoint refreshes nothing")
    func savepointRollbackRefreshesNothing() async {
        let target = RecordingCatalogTarget()
        let service = makeService(target: target)
        let connectionId = UUID()

        service.record(.statementsRan(
            connectionId: connectionId, statements: ["ROLLBACK TO SAVEPOINT s"], databaseType: .postgresql
        ))
        await service.waitUntilIdle(connectionId: connectionId)

        #expect(target.changes.isEmpty)
    }

    @Test("a target others depend on finishes before they start")
    func leadingTargetFinishesFirst() async {
        let log = OrderLog()
        let tree = OrderedCatalogTarget(name: "tree", leads: true, log: log)
        let providers = OrderedCatalogTarget(name: "providers", leads: false, log: log)
        let service = CatalogChangeService(targets: [providers, tree], isSessionLive: { _ in true })
        let connectionId = UUID()

        service.record(.changed(CatalogChange(connectionId: connectionId, kinds: .databases)))
        await service.waitUntilIdle(connectionId: connectionId)

        #expect(log.entries == ["tree start", "tree end", "providers start", "providers end"])
    }

    @Test("dropping a schema refreshes that database's schemas and objects")
    func containerDropScopesToItsDatabase() async {
        let target = RecordingCatalogTarget()
        let service = makeService(target: target)
        let connectionId = UUID()

        service.record(.containerDropped(.schema(database: "shop", schema: "staging"), connectionId: connectionId))
        await service.waitUntilIdle(connectionId: connectionId)

        #expect(target.changes == [CatalogChange(connectionId: connectionId, database: "shop", kinds: [.schemas, .objects])])
    }
}
