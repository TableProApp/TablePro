import Foundation
import TableProPluginKit
import TableProTestSupport
import Testing

@testable import TablePro

@MainActor
private final class ScriptedSearchReader: DatabaseSearchReading {
    var catalog: [DatabaseSearchTarget]
    var outcomes: [String: DatabaseSearchTableResult.Outcome] = [:]
    var failures: [String: String] = [:]
    var gate: AsyncGate?
    var gatedTable: String?
    private(set) var searched: [String] = []

    init(catalog: [DatabaseSearchTarget]) {
        self.catalog = catalog
    }

    func tables() async throws -> [DatabaseSearchTarget] {
        catalog
    }

    func search(
        _ target: DatabaseSearchTarget,
        options: DatabaseSearchOptions
    ) async throws -> DatabaseSearchTableResult.Outcome {
        searched.append(target.name)
        if target.name == gatedTable, let gate {
            await gate.wait()
        }
        if let message = failures[target.name] {
            throw DatabaseError.queryFailed(message)
        }
        return outcomes[target.name] ?? .noMatch
    }
}

@MainActor
struct DatabaseSearchSessionTests {
    private static let users = DatabaseSearchTarget(name: "users", schema: "app")
    private static let orders = DatabaseSearchTarget(name: "orders", schema: "app")
    private static let audit = DatabaseSearchTarget(name: "audit", schema: "log")

    private static func match(_ column: String) -> DatabaseSearchTableResult.Outcome {
        let filter = TableFilter(columnName: column, filterOperator: .contains, value: "ada")
        return .matched(DatabaseSearchMatch(searchedFilters: [filter], matchedFilters: [filter], rowCount: 1, isCapped: false))
    }

    private func makeSession(
        _ reader: ScriptedSearchReader,
        schema: String? = nil
    ) async -> DatabaseSearchSession {
        let session = DatabaseSearchSession(
            launch: DatabaseSearchLaunchRequest(database: "shop", schema: schema),
            scopeDescription: "Local / shop",
            caseMatching: .engine(.caseFoldFunction),
            reader: reader
        )
        await session.loadTablesIfNeeded()
        session.options.term = "ada"
        return session
    }

    private func finish(_ session: DatabaseSearchSession) async {
        await session.runTask?.value
    }

    @Test("A database launch ticks every table, a schema launch only that schema's")
    func preselectionFollowsTheLaunch() async {
        let reader = ScriptedSearchReader(catalog: [Self.users, Self.orders, Self.audit])
        let whole = await makeSession(reader)
        #expect(whole.selectedTargetIds == [Self.users.id, Self.orders.id, Self.audit.id])

        let schema = await makeSession(reader, schema: "log")
        #expect(schema.selectedTargetIds == [Self.audit.id])
        #expect(schema.schemaGroups.map(\.schema) == ["app", "log"])
    }

    @Test("Every ticked table is searched in order and the matches are listed")
    func searchesEveryTickedTable() async {
        let reader = ScriptedSearchReader(catalog: [Self.users, Self.orders, Self.audit])
        reader.outcomes = ["users": Self.match("email"), "audit": Self.match("actor")]
        let session = await makeSession(reader)
        session.setSelected(Self.orders, false)

        session.start()
        await finish(session)

        #expect(reader.searched == ["users", "audit"])
        #expect(session.step == .finished)
        #expect(session.completedCount == 2)
        #expect(session.wasStopped == false)
        #expect(session.matchedResults.map(\.target.name) == ["users", "audit"])
        #expect(session.selectedMatch?.target == Self.users)
    }

    @Test("A table that fails is listed with its error and the search goes on")
    func failureDoesNotEndTheSearch() async {
        let reader = ScriptedSearchReader(catalog: [Self.users, Self.orders, Self.audit])
        reader.failures = ["orders": "permission denied for table orders"]
        reader.outcomes = ["audit": Self.match("actor")]
        let session = await makeSession(reader)

        session.start()
        await finish(session)

        #expect(reader.searched == ["users", "orders", "audit"])
        #expect(session.failedResults.map(\.target.name) == ["orders"])
        #expect(session.failedResults.first?.failure == "permission denied for table orders")
        #expect(session.matchedResults.map(\.target.name) == ["audit"])
        #expect(session.listedResults.map(\.target.name) == ["audit", "orders"])
    }

    @Test("Stop ends the search before the next table and keeps what was found")
    func stopEndsAtTheNextTable() async throws {
        let reader = ScriptedSearchReader(catalog: [Self.users, Self.orders, Self.audit])
        reader.outcomes = ["users": Self.match("email")]
        let gate = AsyncGate()
        reader.gate = gate
        reader.gatedTable = "orders"
        let session = await makeSession(reader)

        session.start()
        try await waitUntil { reader.searched == ["users", "orders"] }
        session.stop()
        await gate.open()
        await finish(session)

        #expect(reader.searched == ["users", "orders"])
        #expect(session.step == .finished)
        #expect(session.wasStopped)
        #expect(session.completedCount == 1)
        #expect(session.matchedResults.map(\.target.name) == ["users"])
    }

    @Test("Edit Search returns to the form and a late read cannot finish the run behind it")
    func editSearchFencesTheRun() async throws {
        let reader = ScriptedSearchReader(catalog: [Self.users])
        let gate = AsyncGate()
        reader.gate = gate
        reader.gatedTable = "users"
        let session = await makeSession(reader)

        session.start()
        try await waitUntil { reader.searched == ["users"] }
        session.editSearch()
        await gate.open()
        await finish(session)

        #expect(session.step == .configuring)
        #expect(session.results.isEmpty)
    }

    @Test("Search is refused without a value or without a table")
    func searchNeedsTermAndTables() async {
        let reader = ScriptedSearchReader(catalog: [Self.users])
        let session = await makeSession(reader)
        session.options.term = "  "
        #expect(!session.canSearch)
        session.options.term = "ada"
        session.deselectAllFiltered()
        #expect(!session.canSearch)
        session.selectAllFiltered()
        #expect(session.canSearch)
    }

    @Test("The table filter narrows the list and Select All acts on what it shows")
    func filterNarrowsSelection() async {
        let reader = ScriptedSearchReader(catalog: [Self.users, Self.orders, Self.audit])
        let session = await makeSession(reader)
        session.deselectAllFiltered()
        session.tableFilter = "ORD"
        #expect(session.filteredTargets == [Self.orders])
        session.selectAllFiltered()
        #expect(session.selectedTargetIds == [Self.orders.id])
    }
}
