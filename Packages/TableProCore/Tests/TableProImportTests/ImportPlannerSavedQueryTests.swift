import Foundation
import Testing

@testable import TableProImport

@Suite("Import planner: saved queries")
struct ImportPlannerSavedQueryTests {
    private typealias Fixtures = ImportFixtures

    private let existingId = UUID()

    private func plan(_ preview: ImportPreview, _ configure: (inout ImportSelection) -> Void = { _ in }) -> ImportPlan {
        var selection = ImportSelection.defaults(for: preview)
        configure(&selection)
        var ids = SequentialIds()
        return ImportPlanner.plan(preview, selection: selection, ids: &ids)
    }

    private func available(
        included: Bool = true,
        nameExists: Bool = false,
        dropped: SavedQueryKeywordDrop? = nil
    ) -> QueryStatus {
        QueryStatus(availability: .available, isIncluded: included, nameExists: nameExists, droppedKeyword: dropped)
    }

    private func unavailable(_ availability: QueryStatus.Availability) -> QueryStatus {
        QueryStatus(availability: availability, isIncluded: false, nameExists: false, droppedKeyword: nil)
    }

    private func duplicatePreview(
        queries: [BundleSavedQuery],
        folders: [BundleQueryFolder] = [],
        librarySavedQueries: [SavedQueryLedger.Entry] = []
    ) throws -> ImportPreview {
        let bundle = try Fixtures.makeBundle(
            connections: [BundleConnection(ref: "c1", settings: Fixtures.settings())],
            queryFolders: folders,
            savedQueries: queries
        )
        let library = ImportLibrarySnapshot(
            connections: [Fixtures.existing(Fixtures.settings(), id: existingId)],
            savedQueries: librarySavedQueries
        )
        return Fixtures.makePreview(bundle, library: library)
    }

    @Test("A query whose connection is not imported is skipped, a global one is planned")
    func connectionSkipped() throws {
        let bundle = try Fixtures.makeBundle(
            connections: [BundleConnection(ref: "c1", settings: Fixtures.settings())],
            savedQueries: [
                BundleSavedQuery(ref: "q1", name: "Scoped", sql: "select 1", connectionRef: "c1"),
                BundleSavedQuery(ref: "q2", name: "Global", sql: "select 2")
            ]
        )
        let preview = Fixtures.makePreview(bundle)

        let result = plan(preview) { selection in
            selection.setSelected(false, connection: "c1", in: preview)
            selection.setIncluded(true, query: "q1")
        }

        #expect(result.queryStatuses["q1"] == unavailable(.connectionSkipped))
        #expect(result.queryStatuses["q2"] == available())
        #expect(result.queries == [
            PlannedQuery(ref: "q2", name: "Global", sql: "select 2", keyword: nil, connectionId: nil, folderPath: [])
        ])
    }

    @Test("Keep Existing scopes queries to the existing connection and skips ones already saved there")
    func keepExistingScope() throws {
        let preview = try duplicatePreview(
            queries: [
                BundleSavedQuery(ref: "q1", name: "Locks", sql: "select 1", connectionRef: "c1"),
                BundleSavedQuery(ref: "q2", name: "Sizes", sql: "select 2", connectionRef: "c1")
            ],
            librarySavedQueries: [SavedQueryLedger.Entry(name: "locks", sql: "select 1 ", keyword: nil, connectionId: existingId)]
        )

        let result = plan(preview) { selection in
            selection.setSelected(true, connection: "c1", in: preview)
            selection.setIncluded(true, query: "q1")
        }

        #expect(result.keptConnections == ["c1": existingId])
        #expect(result.connections.isEmpty)
        #expect(result.queryStatuses["q1"] == unavailable(.alreadySaved))
        #expect(result.queryStatuses["q2"] == available())
        #expect(result.queries.map(\.ref) == ["q2"])
        #expect(result.queries.first?.connectionId == existingId)
        #expect(!result.isEmpty)
    }

    @Test("A query another selected row adds is held back, and keeps its own choice for when that row goes")
    func queryAddedByAnotherRow() throws {
        let bundle = try Fixtures.makeBundle(
            connections: [
                BundleConnection(ref: "c1", settings: Fixtures.settings(name: "One")),
                BundleConnection(ref: "c2", settings: Fixtures.settings(name: "Two"))
            ],
            savedQueries: [
                BundleSavedQuery(ref: "q1", name: "Locks", sql: "select 1", connectionRef: "c1"),
                BundleSavedQuery(ref: "q2", name: "Locks", sql: "select 1", connectionRef: "c2")
            ]
        )
        let library = ImportLibrarySnapshot(connections: [Fixtures.existing(Fixtures.settings(), id: existingId)])
        let preview = Fixtures.makePreview(bundle, library: library)
        let selectBoth: (inout ImportSelection) -> Void = { selection in
            selection.setSelected(true, connection: "c1", in: preview)
            selection.setSelected(true, connection: "c2", in: preview)
        }

        let both = plan(preview, selectBoth)
        #expect(both.keptConnections == ["c1": existingId, "c2": existingId])
        #expect(both.queryStatuses["q2"] == unavailable(.addedByAnotherRow))
        #expect(both.queries.map(\.ref) == ["q1"])

        let firstOff = plan(preview) { selection in
            selectBoth(&selection)
            selection.setIncluded(false, query: "q1")
        }
        #expect(firstOff.queries.map(\.ref) == ["q2"])

        let noneWanted = plan(preview) { selection in
            selectBoth(&selection)
            selection.setIncluded(false, query: "q1")
            selection.setIncluded(false, query: "q2")
        }
        #expect(noneWanted.queries.isEmpty)
    }

    @Test("Replace scopes queries to the replaced connection")
    func replaceScope() throws {
        let preview = try duplicatePreview(
            queries: [BundleSavedQuery(ref: "q1", name: "Locks", sql: "select 1", connectionRef: "c1")],
            librarySavedQueries: [SavedQueryLedger.Entry(name: "Locks", sql: "select 1", keyword: nil, connectionId: existingId)]
        )

        let result = plan(preview) { selection in
            selection.setSelected(true, connection: "c1", in: preview)
            selection.resolve("c1", as: .replace(existingId), in: preview)
        }

        #expect(result.connections.first?.id == existingId)
        #expect(result.queryStatuses["q1"] == unavailable(.alreadySaved))
    }

    @Test("As Copy scopes queries to the new connection, so a match on the original is not a duplicate")
    func asCopyScope() throws {
        let preview = try duplicatePreview(
            queries: [BundleSavedQuery(ref: "q1", name: "Locks", sql: "select 1", connectionRef: "c1")],
            librarySavedQueries: [SavedQueryLedger.Entry(name: "Locks", sql: "select 1", keyword: nil, connectionId: existingId)]
        )

        let result = plan(preview) { selection in
            selection.setSelected(true, connection: "c1", in: preview)
            selection.resolve("c1", as: .addCopy, in: preview)
        }

        #expect(result.queryStatuses["q1"] == available())
        #expect(result.queries.first?.connectionId == Fixtures.uuid(1))
        #expect(result.connections.first?.id == Fixtures.uuid(1))
    }

    @Test("A query with the name of a saved one but different SQL imports with a note")
    func nameExistsNote() throws {
        let preview = try duplicatePreview(
            queries: [BundleSavedQuery(ref: "q1", name: "Locks", sql: "select 2", connectionRef: "c1")],
            librarySavedQueries: [SavedQueryLedger.Entry(name: "Locks", sql: "select 1", keyword: nil, connectionId: existingId)]
        )

        let result = plan(preview) { $0.setSelected(true, connection: "c1", in: preview) }

        #expect(result.queryStatuses["q1"] == available(nameExists: true))
        #expect(result.queries.map(\.ref) == ["q1"])
    }

    @Test("A keyword taken in the library or earlier in the file imports without one")
    func keywordClashes() throws {
        let bundle = try Fixtures.makeBundle(
            connections: [BundleConnection(ref: "c1", settings: Fixtures.settings())],
            savedQueries: [
                BundleSavedQuery(ref: "q1", name: "One", sql: "select 1", keyword: "dau"),
                BundleSavedQuery(ref: "q2", name: "Two", sql: "select 2", keyword: "dau", connectionRef: "c1"),
                BundleSavedQuery(ref: "q3", name: "Three", sql: "select 3", keyword: "lk"),
                BundleSavedQuery(ref: "q4", name: "Four", sql: "select 4", keyword: "has space")
            ]
        )
        let library = ImportLibrarySnapshot(savedQueries: [
            SavedQueryLedger.Entry(name: "Local", sql: "select 0", keyword: "lk", connectionId: UUID())
        ])

        let result = plan(Fixtures.makePreview(bundle, library: library))

        #expect(result.queryStatuses["q1"] == available())
        #expect(result.queryStatuses["q2"] == available(dropped: .inUse("dau")))
        #expect(result.queryStatuses["q3"] == available(dropped: .inUse("lk")))
        #expect(result.queryStatuses["q4"] == available(dropped: .invalid("has space")))
        #expect(result.queries.map(\.keyword) == ["dau", nil, nil, nil])
    }

    @Test("An unchecked query reserves nothing for the rows after it")
    func excludedRowReservesNothing() throws {
        let bundle = try Fixtures.makeBundle(
            connections: [BundleConnection(ref: "c1", settings: Fixtures.settings())],
            savedQueries: [
                BundleSavedQuery(ref: "q1", name: "One", sql: "select 1", keyword: "dau"),
                BundleSavedQuery(ref: "q2", name: "Two", sql: "select 2", keyword: "dau")
            ]
        )

        let result = plan(Fixtures.makePreview(bundle)) { $0.setIncluded(false, query: "q1") }

        #expect(result.queryStatuses["q1"] == available(included: false))
        #expect(result.queryStatuses["q2"] == available())
        #expect(result.queries.map(\.keyword) == ["dau"])
    }

    @Test("An unsuggested query starts unchecked and can be checked")
    func unsuggestedQueryCanBeIncluded() throws {
        let bundle = try Fixtures.makeBundle(
            connections: [BundleConnection(ref: "c1", settings: Fixtures.settings())],
            savedQueries: [BundleSavedQuery(ref: "q1", name: "Script-3", sql: "select 1", connectionRef: "c1")]
        )
        let preview = Fixtures.makePreview(bundle, unsuggestedQueries: ["q1"])

        #expect(plan(preview).queryStatuses["q1"] == available(included: false))
        #expect(plan(preview) { $0.setIncluded(true, query: "q1") }.queries.map(\.ref) == ["q1"])
    }

    @Test("A too large query is never included, even when checked")
    func tooLargeIsNeverIncluded() throws {
        let bundle = try Fixtures.makeBundle(
            connections: [BundleConnection(ref: "c1", settings: Fixtures.settings())],
            savedQueries: [
                BundleSavedQuery(ref: "q1", name: "Huge", sql: String(repeating: "x", count: SavedQuerySize.maximumSyncableByteCount))
            ]
        )
        let oversized = OversizedSavedQuery(ref: "q2", name: "Dump", folderPath: [], connection: "c1", byteCount: 2_000_000)
        let preview = Fixtures.makePreview(bundle, oversizedQueries: [oversized])

        let result = plan(preview) { selection in
            selection.setIncluded(true, query: "q1")
            selection.setIncluded(true, query: "q2")
        }

        #expect(result.queryStatuses["q1"] == unavailable(.tooLarge))
        #expect(result.queryStatuses["q2"] == unavailable(.tooLarge))
        #expect(result.queries.isEmpty)
    }

    @Test("Folder chains are scoped to the planned connection and trimmed until the leaf can hold the query")
    func folderPathsAreTrimmed() throws {
        let bundle = try Fixtures.makeBundle(
            connections: [
                BundleConnection(ref: "c1", settings: Fixtures.settings()),
                BundleConnection(ref: "c2", settings: Fixtures.settings(host: "two"))
            ],
            queryFolders: [
                BundleQueryFolder(ref: "f1", name: "Shared"),
                BundleQueryFolder(ref: "f2", name: "Orders", parentRef: "f1", connectionRef: "c1"),
                BundleQueryFolder(ref: "f3", name: "Daily", parentRef: "f2", connectionRef: "c1"),
                BundleQueryFolder(ref: "f4", name: "Theirs", connectionRef: "c2"),
                BundleQueryFolder(ref: "f5", name: "Inner", parentRef: "f4")
            ],
            savedQueries: [
                BundleSavedQuery(ref: "q1", name: "Scoped", sql: "select 1", folderRef: "f3", connectionRef: "c1"),
                BundleSavedQuery(ref: "q2", name: "Global", sql: "select 2", folderRef: "f3"),
                BundleSavedQuery(ref: "q3", name: "Cut", sql: "select 3", folderRef: "f5", connectionRef: "c1"),
                BundleSavedQuery(ref: "q4", name: "Root", sql: "select 4", folderRef: "f5")
            ]
        )
        let preview = Fixtures.makePreview(bundle)

        let result = plan(preview) { $0.setSelected(false, connection: "c2", in: preview) }

        let target = Fixtures.uuid(1)
        let paths = Dictionary(uniqueKeysWithValues: result.queries.map { ($0.ref, $0.folderPath) })
        #expect(paths["q1"] == [
            PathComponent(name: "Shared", scope: nil, color: nil),
            PathComponent(name: "Orders", scope: target, color: nil),
            PathComponent(name: "Daily", scope: target, color: nil)
        ])
        #expect(paths["q2"] == [PathComponent(name: "Shared", scope: nil, color: nil)])
        #expect(paths["q3"]?.isEmpty == true)
        #expect(paths["q4"]?.isEmpty == true)
    }

    @Test("A global folder under a connection's folder is cut, since the parent cannot hold it")
    func globalChildOfScopedFolderIsCut() throws {
        let bundle = try Fixtures.makeBundle(
            connections: [BundleConnection(ref: "c1", settings: Fixtures.settings())],
            queryFolders: [
                BundleQueryFolder(ref: "f1", name: "Orders", connectionRef: "c1"),
                BundleQueryFolder(ref: "f2", name: "Shared", parentRef: "f1")
            ],
            savedQueries: [
                BundleSavedQuery(ref: "q1", name: "Scoped", sql: "select 1", folderRef: "f2", connectionRef: "c1"),
                BundleSavedQuery(ref: "q2", name: "Global", sql: "select 2", folderRef: "f2")
            ]
        )

        let result = plan(Fixtures.makePreview(bundle))

        let paths = Dictionary(uniqueKeysWithValues: result.queries.map { ($0.ref, $0.folderPath) })
        #expect(paths["q1"] == [PathComponent(name: "Orders", scope: Fixtures.uuid(1), color: nil)])
        #expect(paths["q2"]?.isEmpty == true)
    }
}
