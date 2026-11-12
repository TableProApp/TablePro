import Foundation
@testable import TableProMobile
import TableProModels
import Testing

@MainActor
@Suite("Connection query history list")
struct ConnectionCoordinatorHistoryTests {
    private let fixture: AppStateFixture
    private let appState: AppState
    private let connection = DatabaseConnection(name: "Prod", type: .postgresql, host: "db.example.com")

    init() throws {
        fixture = try AppStateFixture()
        appState = fixture.makeState(syncEnabled: false)
        #expect(appState.addConnection(connection))
    }

    private func makeCoordinator() async -> ConnectionCoordinator {
        let coordinator = ConnectionCoordinator(connection: connection, appState: appState)
        await coordinator.loadHistory()
        return coordinator
    }

    @Test("Running the same query twice in a row lists it once, as the store keeps it")
    func repeatedQueryIsListedOnce() async {
        let coordinator = await makeCoordinator()

        await coordinator.addHistoryItem(QueryHistoryItem(query: "SELECT 1", connectionId: connection.id))
        await coordinator.addHistoryItem(QueryHistoryItem(query: "SELECT 1", connectionId: connection.id))

        #expect(coordinator.queryHistory.count == 1)
        #expect(coordinator.queryHistory.map(\.id) == appState.queryHistory.load(for: connection.id).map(\.id))
    }

    @Test("The same query failing after it succeeded is listed twice")
    func differentOutcomeIsListedAgain() async {
        let coordinator = await makeCoordinator()

        await coordinator.addHistoryItem(QueryHistoryItem(query: "SELECT 1", connectionId: connection.id))
        await coordinator.addHistoryItem(
            QueryHistoryItem(query: "SELECT 1", connectionId: connection.id, wasSuccessful: false, errorMessage: "gone")
        )

        #expect(coordinator.queryHistory.map(\.wasSuccessful) == [true, false])
    }

    @Test("A query past the store's cap drops the oldest entry from the list too")
    func listFollowsTheStoreCap() async {
        for index in 0..<200 {
            appState.queryHistory.save(QueryHistoryItem(query: "SELECT \(index)", connectionId: connection.id))
        }
        let coordinator = await makeCoordinator()
        #expect(coordinator.queryHistory.count == 200)

        await coordinator.addHistoryItem(QueryHistoryItem(query: "SELECT 200", connectionId: connection.id))

        #expect(coordinator.queryHistory.count == 200)
        #expect(coordinator.queryHistory.first?.query == "SELECT 1")
        #expect(coordinator.queryHistory.last?.query == "SELECT 200")
    }

    @Test("A delete lists what the store holds after it, a run another window saved meanwhile included")
    func deleteListsRunsSavedMeanwhile() async throws {
        let coordinator = await makeCoordinator()
        await coordinator.addHistoryItem(QueryHistoryItem(query: "SELECT 1", connectionId: connection.id))
        let first = try #require(coordinator.queryHistory.first?.id)
        appState.queryHistory.save(QueryHistoryItem(query: "SELECT 2", connectionId: connection.id))

        await coordinator.deleteHistoryItem(first).value

        #expect(coordinator.queryHistory.map(\.query) == ["SELECT 2"])
        #expect(appState.queryHistory.load(for: connection.id).map(\.query) == ["SELECT 2"])
    }

    @Test("Clearing empties the list and the store for this connection only")
    func clearEmptiesThisConnection() async {
        let other = UUID()
        appState.queryHistory.save(QueryHistoryItem(query: "SELECT 0", connectionId: other))
        let coordinator = await makeCoordinator()
        await coordinator.addHistoryItem(QueryHistoryItem(query: "SELECT 1", connectionId: connection.id))

        await coordinator.clearHistory().value

        #expect(coordinator.queryHistory.isEmpty)
        #expect(appState.queryHistory.load(for: connection.id).isEmpty)
        #expect(appState.queryHistory.load(for: other).map(\.query) == ["SELECT 0"])
    }

    @Test("A history file that cannot be read or written leaves the listed history in place")
    func unreadableStoreKeepsTheList() async throws {
        appState.queryHistory.save(QueryHistoryItem(query: "SELECT 1", connectionId: connection.id))
        let coordinator = await makeCoordinator()
        let historyFile = fixture.libraryDirectory.appendingPathComponent("query-history.json")
        try FileManager.default.removeItem(at: historyFile)
        try FileManager.default.createDirectory(at: historyFile, withIntermediateDirectories: false)
        try Data("locked".utf8).write(to: historyFile.appendingPathComponent("entry"))

        await coordinator.addHistoryItem(QueryHistoryItem(query: "SELECT 2", connectionId: connection.id))

        #expect(coordinator.queryHistory.map(\.query) == ["SELECT 1"])
    }
}
