import Foundation
@testable import TablePro
import Testing

@MainActor
@Suite("ClosedTabDraftStorage")
struct ClosedTabDraftStorageTests {
    private func makeStorage() throws -> ClosedTabDraftStorage {
        let suite = "ClosedTabDraftStorageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return ClosedTabDraftStorage(defaults: defaults)
    }

    @Test("Consuming with no stored draft returns nil")
    func defaultsNil() throws {
        let storage = try makeStorage()
        #expect(storage.consumeQuery(connectionId: UUID()) == nil)
    }

    @Test("Saved draft round-trips on consume")
    func saveAndConsume() throws {
        let storage = try makeStorage()
        let connId = UUID()
        storage.saveQuery("SELECT 1", connectionId: connId)
        #expect(storage.consumeQuery(connectionId: connId) == "SELECT 1")
    }

    @Test("A draft is consumed only once")
    func consumeOnce() throws {
        let storage = try makeStorage()
        let connId = UUID()
        storage.saveQuery("SELECT 1", connectionId: connId)
        #expect(storage.consumeQuery(connectionId: connId) == "SELECT 1")
        #expect(storage.consumeQuery(connectionId: connId) == nil)
    }

    @Test("Drafts are isolated per connection")
    func perConnectionIsolation() throws {
        let storage = try makeStorage()
        let a = UUID()
        let b = UUID()
        storage.saveQuery("SELECT a", connectionId: a)
        #expect(storage.consumeQuery(connectionId: b) == nil)
        #expect(storage.consumeQuery(connectionId: a) == "SELECT a")
    }

    @Test("Removing a draft clears the stored value")
    func removeDraftClears() throws {
        let storage = try makeStorage()
        let connId = UUID()
        storage.saveQuery("SELECT 1", connectionId: connId)
        storage.removeDraft(for: connId)
        #expect(storage.consumeQuery(connectionId: connId) == nil)
    }

    @Test("Removing drafts in batch clears across connections")
    func removeDraftsBatchClears() throws {
        let storage = try makeStorage()
        let a = UUID()
        let b = UUID()
        storage.saveQuery("SELECT a", connectionId: a)
        storage.saveQuery("SELECT b", connectionId: b)
        storage.removeDrafts(for: Set([a, b]))
        #expect(storage.consumeQuery(connectionId: a) == nil)
        #expect(storage.consumeQuery(connectionId: b) == nil)
    }

    @Test("Queries above the cap are truncated")
    func capApplied() throws {
        let storage = try makeStorage()
        let connId = UUID()
        let oversized = String(repeating: "a", count: TabQueryContent.maxPersistableQuerySize + 1)
        storage.saveQuery(oversized, connectionId: connId)
        let restored = try #require(storage.consumeQuery(connectionId: connId))
        #expect((restored as NSString).length == TabQueryContent.maxPersistableQuerySize)
    }

    @Test("Blank query tabs produce no draft candidate")
    func blankQueryNotSaved() {
        let tab = QueryTab(query: "   \n\t ")
        #expect(ClosedTabDraftStorage.draftCandidate(from: [tab], selectedTabId: nil) == nil)
    }

    @Test("File-backed tabs are excluded from draft candidates")
    func fileBackedTabExcluded() {
        var tab = QueryTab(query: "SELECT 1")
        tab.content.sourceFileURL = URL(fileURLWithPath: "/tmp/query.sql")
        #expect(ClosedTabDraftStorage.draftCandidate(from: [tab], selectedTabId: nil) == nil)
    }

    @Test("Table tabs are excluded from draft candidates")
    func tableTabExcluded() {
        let tab = QueryTab(query: "SELECT 1", tabType: .table, tableName: "users")
        #expect(ClosedTabDraftStorage.draftCandidate(from: [tab], selectedTabId: nil) == nil)
    }

    @Test("The selected tab is preferred as the draft candidate")
    func prefersSelectedTab() {
        let first = QueryTab(query: "SELECT first")
        let second = QueryTab(query: "SELECT second")
        let candidate = ClosedTabDraftStorage.draftCandidate(
            from: [first, second],
            selectedTabId: second.id
        )
        #expect(candidate == "SELECT second")
    }

    @Test("Falls back to the first candidate when no tab is selected")
    func fallsBackToFirstTab() {
        let first = QueryTab(query: "SELECT first")
        let second = QueryTab(query: "SELECT second")
        let candidate = ClosedTabDraftStorage.draftCandidate(
            from: [first, second],
            selectedTabId: nil
        )
        #expect(candidate == "SELECT first")
    }
}
