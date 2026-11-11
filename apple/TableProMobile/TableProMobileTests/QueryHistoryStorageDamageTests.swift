import Foundation
import Testing
@testable import TableProMobile

struct QueryHistoryStorageDamageTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("ios-history-damage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private var historyURL: URL {
        directory.appendingPathComponent("query-history.json")
    }

    private func setAsideCopies() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("query-history.damaged-") }
    }

    @Test("A history file that does not decode is set aside, not written over")
    func undecodableFileIsSetAside() throws {
        let damaged = Data("[{\"id\": \"not-a-uuid\"".utf8)
        try damaged.write(to: historyURL)
        let storage = QueryHistoryStorage(directory: directory)

        #expect(storage.save(QueryHistoryItem(query: "SELECT 1", connectionId: UUID())))

        let copies = try setAsideCopies()
        #expect(copies.count == 1)
        #expect(try copies.first.map { try Data(contentsOf: $0) } == damaged)
        #expect(storage.loadAll().map(\.query) == ["SELECT 1"])
    }

    @Test("Only a clear that asks for it deletes the set-aside copy, even once no history is left")
    func onlyAnExplicitClearDeletesTheSetAsideCopy() throws {
        try Data("not json".utf8).write(to: historyURL)
        let storage = QueryHistoryStorage(directory: directory)
        let first = UUID()
        let second = UUID()
        #expect(storage.save(QueryHistoryItem(query: "SELECT 1", connectionId: first)))
        #expect(storage.save(QueryHistoryItem(query: "SELECT 2", connectionId: second)))
        #expect(storage.hasSetAsideCopies)

        storage.clearAll(for: [first])
        storage.clearAll(for: [second])
        #expect(storage.loadAll().isEmpty)
        #expect(storage.hasSetAsideCopies)

        storage.clearAll(for: [first], removingSetAsideCopies: true)
        #expect(!storage.hasSetAsideCopies)
        #expect(try setAsideCopies().isEmpty)
    }

    @Test("Deleting a connection keeps the set-aside copy, which holds every connection's history")
    @MainActor
    func deletingAConnectionKeepsTheSetAsideCopy() throws {
        try Data("not json".utf8).write(to: historyURL)
        let storage = QueryHistoryStorage(directory: directory)
        let deleted = UUID()
        #expect(storage.save(QueryHistoryItem(query: "SELECT 1", connectionId: deleted)))
        let suite = "QueryHistoryStorageDamageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let localState = ConnectionLocalState(
            secrets: ConnectionSecrets(secureStore: MockSecureStore()),
            queryHistory: storage,
            defaults: defaults
        )

        localState.purge([deleted])

        #expect(storage.loadAll().isEmpty)
        #expect(storage.hasSetAsideCopies)
        #expect(try setAsideCopies().count == 1)
    }

    @Test("A history file that decodes is kept and appended to")
    func readableFileIsKept() throws {
        let storage = QueryHistoryStorage(directory: directory)
        #expect(storage.save(QueryHistoryItem(query: "SELECT 1", connectionId: UUID())))

        #expect(storage.save(QueryHistoryItem(query: "SELECT 2", connectionId: UUID())))

        #expect(try setAsideCopies().isEmpty)
        #expect(storage.loadAll().map(\.query) == ["SELECT 1", "SELECT 2"])
    }
}
