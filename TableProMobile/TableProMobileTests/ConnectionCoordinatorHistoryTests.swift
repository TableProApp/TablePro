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

    private func makeCoordinator() -> ConnectionCoordinator {
        let coordinator = ConnectionCoordinator(connection: connection, appState: appState)
        coordinator.loadHistory()
        return coordinator
    }

    @Test("Running the same query twice in a row lists it once, as the store keeps it")
    func repeatedQueryIsListedOnce() {
        let coordinator = makeCoordinator()

        coordinator.addHistoryItem(QueryHistoryItem(query: "SELECT 1", connectionId: connection.id))
        coordinator.addHistoryItem(QueryHistoryItem(query: "SELECT 1", connectionId: connection.id))

        #expect(coordinator.queryHistory.count == 1)
        #expect(coordinator.queryHistory.map(\.id) == appState.queryHistory.load(for: connection.id).map(\.id))
    }

    @Test("The same query failing after it succeeded is listed twice")
    func differentOutcomeIsListedAgain() {
        let coordinator = makeCoordinator()

        coordinator.addHistoryItem(QueryHistoryItem(query: "SELECT 1", connectionId: connection.id))
        coordinator.addHistoryItem(
            QueryHistoryItem(query: "SELECT 1", connectionId: connection.id, wasSuccessful: false, errorMessage: "gone")
        )

        #expect(coordinator.queryHistory.map(\.wasSuccessful) == [true, false])
    }

    @Test("A query past the store's cap drops the oldest entry from the list too")
    func listFollowsTheStoreCap() {
        for index in 0..<200 {
            appState.queryHistory.save(QueryHistoryItem(query: "SELECT \(index)", connectionId: connection.id))
        }
        let coordinator = makeCoordinator()
        #expect(coordinator.queryHistory.count == 200)

        coordinator.addHistoryItem(QueryHistoryItem(query: "SELECT 200", connectionId: connection.id))

        #expect(coordinator.queryHistory.count == 200)
        #expect(coordinator.queryHistory.first?.query == "SELECT 1")
        #expect(coordinator.queryHistory.last?.query == "SELECT 200")
    }

    @Test("A history file that cannot be read or written leaves the listed history in place")
    func unreadableStoreKeepsTheList() throws {
        appState.queryHistory.save(QueryHistoryItem(query: "SELECT 1", connectionId: connection.id))
        let coordinator = makeCoordinator()
        let historyFile = fixture.libraryDirectory.appendingPathComponent("query-history.json")
        try FileManager.default.removeItem(at: historyFile)
        try FileManager.default.createDirectory(at: historyFile, withIntermediateDirectories: false)
        try Data("locked".utf8).write(to: historyFile.appendingPathComponent("entry"))

        coordinator.addHistoryItem(QueryHistoryItem(query: "SELECT 2", connectionId: connection.id))

        #expect(coordinator.queryHistory.map(\.query) == ["SELECT 1"])
    }
}
