import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class StaticSearchReader: DatabaseSearchReading {
    func tables() async throws -> [DatabaseSearchTarget] { [] }

    func search(
        _ target: DatabaseSearchTarget,
        options: DatabaseSearchOptions
    ) async throws -> DatabaseSearchTableResult.Outcome {
        .noMatch
    }
}

@MainActor
struct DatabaseSearchResultOpeningTests {
    private func makeCoordinator() -> MainContentCoordinator {
        MainContentCoordinator(
            connection: TestFixtures.makeConnection(database: "shop"),
            tabManager: QueryTabManager(),
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
    }

    @Test("Opening a result opens the table in a tab of its own, filtered to the matched columns")
    func openingAResultOpensAFilteredTab() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }
        var opened: [EditorTabPayload] = []
        coordinator.openTabInNewWindow = { opened.append($0) }

        let email = TableFilter(columnName: "email", filterOperator: .contains, value: "ada")
        let name = TableFilter(columnName: "name", filterOperator: .contains, value: "ada")
        let result = DatabaseSearchTableResult(
            target: DatabaseSearchTarget(name: "customers", schema: "sales"),
            outcome: .matched(DatabaseSearchMatch(
                searchedFilters: [email, name], matchedFilters: [email], rowCount: 3, isCapped: false
            ))
        )
        let session = DatabaseSearchSession(
            launch: DatabaseSearchLaunchRequest(database: "archive", schema: nil),
            scopeDescription: "",
            caseMatching: .engine(.caseFoldFunction),
            reader: StaticSearchReader()
        )
        coordinator.activeSheet = .searchDatabase(session)

        coordinator.openDatabaseSearchResult(result, in: session)

        #expect(coordinator.activeSheet == nil)
        #expect(opened.count == 1)
        let payload = opened.first
        #expect(payload?.tabType == .table)
        #expect(payload?.tableName == "customers")
        #expect(payload?.schemaName == "sales")
        #expect(payload?.databaseName == "archive")
        #expect(payload?.forcesNewTab == true)
        #expect(payload?.initialFilterState?.appliedFilters == [email])
        #expect(payload?.initialFilterState?.filterLogicMode == .or)
    }

    @Test("A result without a match opens nothing")
    func failedResultOpensNothing() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }
        var opened: [EditorTabPayload] = []
        coordinator.openTabInNewWindow = { opened.append($0) }
        let session = DatabaseSearchSession(
            launch: DatabaseSearchLaunchRequest(database: "shop", schema: nil),
            scopeDescription: "",
            caseMatching: .engine(.caseFoldFunction),
            reader: StaticSearchReader()
        )

        coordinator.openDatabaseSearchResult(
            DatabaseSearchTableResult(target: DatabaseSearchTarget(name: "t", schema: nil), outcome: .failed("x")),
            in: session
        )

        #expect(opened.isEmpty)
    }

    @Test("Reopening the search on the same database keeps its session, another scope starts a new one")
    func sessionIsKeptPerScope() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }

        let first = coordinator.databaseSearchSession(for: DatabaseSearchLaunchRequest(database: "shop", schema: nil))
        let again = coordinator.databaseSearchSession(for: DatabaseSearchLaunchRequest(database: "shop", schema: nil))
        let other = coordinator.databaseSearchSession(for: DatabaseSearchLaunchRequest(database: "shop", schema: "sales"))

        #expect(first === again)
        #expect(first !== other)
        #expect(coordinator.databaseSearchSession === other)
    }
}
