import Foundation
import Testing
@testable import TableProMobile

@Suite("FileBookmarkStore")
struct FileBookmarkStoreTests {
    private func makeStore() -> (FileBookmarkStore, String) {
        let suiteName = "test.fileBookmark.\(UUID().uuidString)"
        return (FileBookmarkStore(suiteName: suiteName), suiteName)
    }

    @Test("saves and resolves a bookmark for a connection id")
    func saveAndRead() {
        let (store, suiteName) = makeStore()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        let id = UUID()
        let bookmark = Data("bookmark-bytes".utf8)
        store.save(bookmark, for: id)

        #expect(store.bookmark(for: id) == bookmark)
    }

    @Test("returns nil for an unknown connection id")
    func missingReturnsNil() {
        let (store, suiteName) = makeStore()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        #expect(store.bookmark(for: UUID()) == nil)
    }

    @Test("delete removes a stored bookmark")
    func deleteRemoves() {
        let (store, suiteName) = makeStore()
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        let id = UUID()
        store.save(Data("x".utf8), for: id)
        store.delete(for: id)

        #expect(store.bookmark(for: id) == nil)
    }
}
