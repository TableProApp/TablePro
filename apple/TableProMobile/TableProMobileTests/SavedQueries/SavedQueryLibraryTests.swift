import Foundation
@testable import TableProMobile
import TableProModels
import Testing

// The saved queries in the core's store, with the previous stable's `saved-queries.json` kept in step.
@MainActor
struct SavedQueryLibraryTests {
    private let directory: URL
    private let defaults: UserDefaults

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("saved-queries-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults = try #require(UserDefaults(suiteName: "com.TablePro.tests.SavedQueries.\(UUID().uuidString)"))
    }

    private var legacy: SavedQueryPersistence {
        SavedQueryPersistence(directory: directory)
    }

    private func makeLibrary() -> SavedQueryLibrary {
        let host = MobileCoreHost(directory: directory.appendingPathComponent("Core"), clientVersion: "test") {
            ConnectionKeychainSecrets(secureStore: MockSecureStore())
        }
        return SavedQueryLibrary(
            directory: directory,
            store: CoreSavedQueryStore(host: host, directory: directory, defaults: defaults)
        )
    }

    private static func query(_ name: String, keyword: String? = nil) -> SavedQuery {
        SavedQuery(
            name: name,
            query: "SELECT 1",
            keyword: keyword,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    @Test("A query saved here is in the core's store and in the previous stable's file")
    func aSaveReachesBothSides() throws {
        let saved = Self.query("Revenue")
        #expect(makeLibrary().insert(saved))

        #expect(makeLibrary().contents.queries.map(\.id) == [saved.id])
        #expect(try legacy.load().queries.map(\.id) == [saved.id])
    }

    @Test("The first launch on the core takes the saved queries the previous stable kept, folders included")
    func theFirstLaunchTakesThePreviousStablesFile() throws {
        let folder = SavedQueryFolder(name: "Reports", createdAt: Date(timeIntervalSince1970: 1_000))
        var kept = Self.query("Revenue", keyword: "rev")
        kept.folderId = folder.id
        try legacy.save(SavedQueryContents(queries: [kept], folders: [folder]))

        let library = makeLibrary()

        #expect(library.status == .ready)
        #expect(library.contents.queries == [kept])
        #expect(library.contents.folders.map(\.id) == [folder.id])
    }

    @Test("An edit the previous stable made while the core's store stayed as this build left it is read back")
    func thePreviousStablesEditIsReadBack() throws {
        let first = Self.query("Revenue")
        #expect(makeLibrary().insert(first))
        let added = Self.query("Costs")
        var file = try legacy.load()
        file.queries.append(added)
        try legacy.save(file)

        let library = makeLibrary()

        #expect(Set(library.contents.queries.map(\.id)) == [first.id, added.id])
    }

    @Test("A query the engine wrote between a read and an edit stays through that edit, and shows after the pass")
    func aPulledQueryStaysThroughALocalEdit() throws {
        let library = makeLibrary()
        let local = Self.query("Revenue")
        #expect(library.insert(local))
        let pulled = Self.query("From the Mac")
        try ElsewhereWriter.write(query: pulled, in: directory)

        #expect(library.update(local.id) { $0.name = "Revenue by month" })
        library.reloadAfterSync()

        let names = Set(library.contents.queries.map(\.name))
        #expect(names == ["Revenue by month", "From the Mac"])
        #expect(Set(try legacy.load().queries.map(\.name)) == names)
    }

    @Test("A rename made before the app read a pass keeps the SQL the pass wrote to the same query")
    func aRenameOverAPassKeepsItsOtherFields() throws {
        let library = makeLibrary()
        let local = Self.query("Revenue")
        #expect(library.insert(local))
        let pulled = SavedQuery(
            id: local.id,
            name: local.name,
            query: "SELECT 2",
            createdAt: local.createdAt,
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )
        try ElsewhereWriter.write(query: pulled, in: directory)

        #expect(library.update(local.id) { $0.name = "Revenue by month" })

        let stored = try #require(makeLibrary().contents.query(local.id))
        #expect(stored.name == "Revenue by month")
        #expect(stored.query == "SELECT 2")
    }

    @Test("An edit of a query deleted meanwhile reports it and writes nothing")
    func anEditOfAQueryDeletedElsewhereWritesNothing() throws {
        let library = makeLibrary()
        let query = Self.query("Revenue")
        #expect(library.insert(query))
        #expect(library.deleteQuery(query.id))

        #expect(!library.update(query.id) { $0.name = "Renamed" })
        #expect(library.contents.queries.isEmpty)
        #expect(try legacy.load().queries.isEmpty)
    }
}
