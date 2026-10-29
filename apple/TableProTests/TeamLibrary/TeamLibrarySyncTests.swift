//
//  TeamLibrarySyncTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProCloudAPI
import TableProImport
import TableProTestSupport
import Testing

@MainActor
struct TeamLibrarySyncTests {
    nonisolated private static let team = TeamLibraryFixture.team

    // MARK: - Pull

    @Test("The first sync pulls a snapshot and stores its cursor, which the next launch pulls from")
    func cursorPersists() async throws {
        let fixture = try await TeamLibraryFixture { library in
            library.write(Self.team, kind: "query", clientID: "q1", data: TeamLibraryFixture.queryData("Orders"))
        }

        #expect(await fixture.sync.sync() == .synced)
        #expect(fixture.sync.content.queries.map(\.name) == ["Orders"])
        let first = try #require(await fixture.pulls().last)
        #expect(TeamLibraryFixture.cursor(of: first) == nil, "No cursor asks for a snapshot")

        await fixture.library { $0.write(Self.team, kind: "query", clientID: "q2", data: TeamLibraryFixture.queryData("Users")) }
        fixture.relaunch()
        #expect(fixture.sync.content.queries.map(\.name) == ["Orders"], "The stored library shows before any pull")
        #expect(await fixture.sync.sync() == .synced)

        let second = try #require(await fixture.pulls().last)
        #expect(TeamLibraryFixture.cursor(of: second) == "r1")
        #expect(fixture.sync.content.queries.map(\.name) == ["Orders", "Users"])
    }

    @Test("A snapshot larger than a page is read to its last page before it replaces anything")
    func snapshotPages() async throws {
        let fixture = try await TeamLibraryFixture { library in
            library.pageSize = 2
            for index in 1...5 {
                library.write(Self.team, kind: "query", clientID: "q\(index)", data: TeamLibraryFixture.queryData("Q\(index)"))
            }
        }

        #expect(await fixture.sync.sync() == .synced)

        #expect(await fixture.pulls().map { TeamLibraryFixture.cursor(of: $0) } == [nil, "s2:5", "s4:5"])
        #expect(fixture.sync.content.queries.map(\.name) == ["Q1", "Q2", "Q3", "Q4", "Q5"])
    }

    @Test("A pulled tombstone takes the item off the library")
    func tombstoneRemovesItem() async throws {
        let fixture = try await TeamLibraryFixture { library in
            library.write(Self.team, kind: "query", clientID: "q1", data: TeamLibraryFixture.queryData("Orders"))
            library.write(Self.team, kind: "query", clientID: "q2", data: TeamLibraryFixture.queryData("Users"))
        }
        await fixture.sync.sync()

        await fixture.library { $0.write(Self.team, kind: "query", clientID: "q1", data: nil) }
        await fixture.sync.sync()

        #expect(fixture.sync.content.queries.map(\.name) == ["Users"])
        let pulled = try #require(await fixture.pulls().last)
        #expect(TeamLibraryFixture.cursor(of: pulled) == "r2", "An incremental pull, not a snapshot")
    }

    @Test("A query moved to another folder by someone else shows under that folder after the next pull")
    func pulledFolderMove() async throws {
        let fixture = try await TeamLibraryFixture { library in
            library.write(Self.team, kind: "folder", clientID: "f1", data: TeamLibraryFixture.folderData("Reports"))
            library.write(Self.team, kind: "folder", clientID: "f2", data: TeamLibraryFixture.folderData("Archive"))
            library.write(Self.team, kind: "query", clientID: "q1", data: TeamLibraryFixture.queryData("Orders", folder: "f1"))
        }
        await fixture.sync.sync()
        #expect(fixture.sync.content.queries.first?.folderName == "Reports")

        await fixture.library {
            $0.write(Self.team, kind: "query", clientID: "q1", data: TeamLibraryFixture.queryData("Orders", folder: "f2"))
        }
        await fixture.sync.sync()

        #expect(fixture.sync.content.queries.first?.folderName == "Archive")
    }

    @Test("An expired cursor pulls a snapshot")
    func expiredCursorPullsSnapshot() async throws {
        let fixture = try await TeamLibraryFixture { library in
            library.write(Self.team, kind: "query", clientID: "q1", data: TeamLibraryFixture.queryData("Orders"))
        }
        await fixture.sync.sync()
        await fixture.library {
            $0.write(Self.team, kind: "query", clientID: "q2", data: TeamLibraryFixture.queryData("Users"))
            $0.floor[Self.team] = 2
        }

        #expect(await fixture.sync.sync() == .synced)

        #expect(await fixture.pulls().suffix(2).map { TeamLibraryFixture.cursor(of: $0) } == ["r1", nil])
        #expect(fixture.sync.content.queries.map(\.name) == ["Orders", "Users"])
    }

    // MARK: - Push

    @Test("Publishing pushes at most 500 changes a request, then pulls from the last pull's cursor, never the push's")
    func pushesInBatchesAndKeepsThePullCursor() async throws {
        let fixture = try await TeamLibraryFixture { library in
            library.write(Self.team, kind: "query", clientID: "theirs", data: TeamLibraryFixture.queryData("Theirs"))
            library.pushCursorOffset = 1_000
        }
        let favorites = (0..<1_200).map { TeamLibraryFixture.favorite(name: "Q\($0)") }

        let result = try await fixture.sync.publishSavedQueries(favorites: favorites, folders: [], to: Self.team)

        #expect(result == .published(1_200))
        let pushes = await fixture.pushes()
        #expect(pushes.map(\.count) == [500, 500, 200])
        let pullCursors = await fixture.pulls().map { TeamLibraryFixture.cursor(of: $0) }
        #expect(pullCursors == [nil, "r1", "r501", "r1001"], "The pull after the push pages on from the snapshot's cursor")
        #expect(fixture.sync.content.queries.count == 1_201)
    }

    @Test("Publishing what the team already holds pushes nothing")
    func unchangedPublishPushesNothing() async throws {
        let fixture = try await TeamLibraryFixture()
        let favorite = TeamLibraryFixture.favorite(name: "Orders")
        _ = try await fixture.sync.publishSavedQueries(favorites: [favorite], folders: [], to: Self.team)

        let again = try await fixture.sync.publishSavedQueries(favorites: [favorite], folders: [], to: Self.team)

        #expect(again == .unchanged)
        #expect(await fixture.pushes().count == 1)
    }

    @Test("Client IDs go out in lowercase, folders before the queries in them")
    func lowercaseClientIDs() async throws {
        let fixture = try await TeamLibraryFixture()
        let folder = SQLFavoriteFolder(id: UUID(), name: "Reports")
        let connection = UUID()
        let favorite = TeamLibraryFixture.favorite(name: "Orders", folder: folder.id, connection: connection)

        _ = try await fixture.sync.publishSavedQueries(favorites: [favorite], folders: [folder], to: Self.team)

        let changes = try #require(await fixture.pushes().first)
        #expect(changes.map { $0["kind"] as? String } == ["folder", "query"])
        #expect(changes[0]["client_id"] as? String == folder.id.uuidString.lowercased())
        #expect(changes[1]["client_id"] as? String == favorite.id.uuidString.lowercased())
        let data = try #require(changes[1]["data"] as? [String: Any])
        #expect(data["folder_client_id"] as? String == folder.id.uuidString.lowercased())
        #expect(data["connection_client_id"] as? String == connection.uuidString.lowercased())
        #expect(changes.allSatisfy { $0["base_version"] == nil || $0["base_version"] is NSNull })
    }

    @Test("A pulled client ID in another case is the same item: the update keeps the team's spelling and version")
    func pulledIDsMatchWithoutCase() async throws {
        let id = UUID()
        let fixture = try await TeamLibraryFixture { library in
            library.write(Self.team, kind: "query", clientID: id.uuidString, data: TeamLibraryFixture.queryData("Old"))
        }

        let result = try await fixture.sync.publishSavedQueries(
            favorites: [TeamLibraryFixture.favorite(id, name: "New")],
            folders: [],
            to: Self.team
        )

        #expect(result == .published(1))
        let change = try #require(await fixture.pushes().first?.first)
        #expect(change["client_id"] as? String == id.uuidString)
        #expect(change["base_version"] as? Int == 1)
        let stored = await fixture.server.library.live(Self.team)
        #expect(stored.count == 1)
        #expect(stored.first?.data?["name"] as? String == "New")
    }

    @Test("Deleting a published folder pushes the moves of what others keep in it, then the deletes")
    func folderDeletePushesMoves() async throws {
        let parent = SQLFavoriteFolder(id: UUID(), name: "Team")
        let child = SQLFavoriteFolder(id: UUID(), name: "Reports", parentId: parent.id)
        let mine = TeamLibraryFixture.favorite(name: "Mine", folder: child.id)
        let fixture = try await TeamLibraryFixture()
        _ = try await fixture.sync.publishSavedQueries(favorites: [mine], folders: [parent, child], to: Self.team)
        let childID = child.id.uuidString.lowercased()
        await fixture.library {
            $0.write(Self.team, kind: "query", clientID: "theirs", data: TeamLibraryFixture.queryData("Theirs", folder: childID))
        }

        let moved = TeamLibraryFixture.favorite(mine.id, name: "Mine", folder: parent.id)
        let result = try await fixture.sync.publishSavedQueries(favorites: [moved], folders: [parent], to: Self.team)

        #expect(result == .published(3))
        let changes = try #require(await fixture.pushes().last)
        #expect(changes.map { "\($0["op"] ?? "") \($0["kind"] ?? "") \($0["client_id"] ?? "")" } == [
            "upsert query \(mine.id.uuidString.lowercased())",
            "upsert query theirs",
            "delete folder \(childID)"
        ])
        let theirs = await fixture.server.library.item(Self.team, kind: "query", clientID: "theirs")
        #expect(theirs?.data?["folder_client_id"] as? String == parent.id.uuidString.lowercased())
        #expect(await fixture.server.library.item(Self.team, kind: "folder", clientID: childID)?.deleted == true)
    }

    @Test("Moving someone else's query out of a deleted folder leaves it theirs: publishing again removes nothing")
    func movedQueryStaysTheirs() async throws {
        let folder = SQLFavoriteFolder(id: UUID(), name: "Archive")
        let mine = TeamLibraryFixture.favorite(name: "Mine", folder: folder.id)
        let fixture = try await TeamLibraryFixture()
        _ = try await fixture.sync.publishSavedQueries(favorites: [mine], folders: [folder], to: Self.team)
        await fixture.library {
            $0.write(Self.team, kind: "query", clientID: "theirs", data: TeamLibraryFixture.queryData("Theirs", folder: folder.id.uuidString.lowercased()))
        }
        let moved = TeamLibraryFixture.favorite(mine.id, name: "Mine")
        let deleted = try await fixture.sync.publishSavedQueries(favorites: [moved], folders: [], to: Self.team)
        #expect(deleted == .published(3))

        let again = try await fixture.sync.publishSavedQueries(favorites: [moved], folders: [], to: Self.team)

        #expect(again == .unchanged)
        #expect(await fixture.pushes().count == 2)
        let theirs = try #require(await fixture.server.library.item(Self.team, kind: "query", clientID: "theirs"))
        #expect(!theirs.deleted)
        #expect(theirs.data?["folder_client_id"] == nil, "Moved to the top level")
    }

    @Test("Keep Mine on a move that conflicted pushes the move, and the query stays someone else's")
    func keepMineOnAMove() async throws {
        let folder = SQLFavoriteFolder(id: UUID(), name: "Archive")
        let folderID = folder.id.uuidString.lowercased()
        let fixture = try await TeamLibraryFixture()
        _ = try await fixture.sync.publishSavedQueries(favorites: [], folders: [folder], to: Self.team)
        await fixture.library {
            $0.write(Self.team, kind: "query", clientID: "theirs", data: TeamLibraryFixture.queryData("Theirs", folder: folderID))
        }
        let gate = AsyncGate()
        await fixture.library { $0.pushGate = gate }
        let deleting = Task { try await fixture.sync.publishSavedQueries(favorites: [], folders: [], to: Self.team) }
        await gate.arrived(1)
        // Another admin edits the query while the push is out, so the move's base version is stale.
        await fixture.library {
            $0.write(Self.team, kind: "query", clientID: "theirs", data: TeamLibraryFixture.queryData("Theirs, edited", folder: folderID))
        }
        await gate.open()
        #expect(try await deleting.value == .conflicts(1))
        let conflict = try #require(fixture.sync.conflicts.first)
        #expect(conflict.isMove)

        await fixture.sync.resolve(conflict, keepingMine: true)
        let again = try await fixture.sync.publishSavedQueries(favorites: [], folders: [], to: Self.team)

        #expect(again == .unchanged)
        let theirs = try #require(await fixture.server.library.item(Self.team, kind: "query", clientID: "theirs"))
        #expect(!theirs.deleted)
        #expect(theirs.data?["folder_client_id"] == nil)
    }

    // MARK: - Conflicts

    @Test("A push over an item someone changed since the pull leaves a conflict holding their copy")
    func conflictKeepsTheirCopy() async throws {
        let fixture = try await conflicted()

        let conflict = try #require(fixture.sync.conflicts.first)
        #expect(fixture.sync.conflicts.count == 1)
        #expect(conflict.edit.baseVersion == 1)
        #expect(fixture.sync.current(for: conflict)?.version == 2)
        #expect(fixture.sync.content.queries.map(\.query) == ["select theirs"])
    }

    @Test("Keep Mine pushes this Mac's copy over the team's current version")
    func keepMine() async throws {
        let fixture = try await conflicted()
        let conflict = try #require(fixture.sync.conflicts.first)

        await fixture.sync.resolve(conflict, keepingMine: true)

        #expect(fixture.sync.conflicts.isEmpty)
        let last = try #require(await fixture.pushes().last?.first)
        #expect(last["base_version"] as? Int == 2)
        let stored = await fixture.server.library.item(Self.team, kind: "query", clientID: Self.conflictID)
        #expect(stored?.data?["query"] as? String == "select mine")
        #expect(fixture.sync.content.queries.map(\.query) == ["select mine"])
    }

    @Test("Keep Theirs drops this Mac's copy and pushes nothing")
    func keepTheirs() async throws {
        let fixture = try await conflicted()
        let conflict = try #require(fixture.sync.conflicts.first)
        let pushed = await fixture.pushes().count

        await fixture.sync.resolve(conflict, keepingMine: false)

        #expect(fixture.sync.conflicts.isEmpty)
        #expect(await fixture.pushes().count == pushed)
        let stored = await fixture.server.library.item(Self.team, kind: "query", clientID: Self.conflictID)
        #expect(stored?.data?["query"] as? String == "select theirs")
        fixture.relaunch()
        #expect(fixture.sync.conflicts.isEmpty, "The choice is stored")
    }

    @Test("A conflict over a copy the team already holds as sent resolves itself")
    func identicalConflictIsNoConflict() async throws {
        let id = UUID()
        let fixture = try await TeamLibraryFixture()
        await fixture.sync.sync()
        var state = try #require(fixture.store.loadAll().first)
        state.pending = try TeamLibraryPublishPlan.savedQueries(
            favorites: [TeamLibraryFixture.favorite(id, name: "Orders")],
            folders: [],
            in: state
        )
        fixture.store.save(state)
        let clientID = id.uuidString.lowercased()
        await fixture.library {
            $0.write(Self.team, kind: "query", clientID: clientID, data: TeamLibraryFixture.queryData("Orders"))
        }
        fixture.relaunch()

        #expect(await fixture.sync.sync() == .synced)

        #expect(fixture.sync.conflicts.isEmpty)
        #expect(await fixture.server.library.item(Self.team, kind: "query", clientID: clientID)?.version == 1)
    }

    @Test("Publishing a query deleted on the team asks first, and Keep Theirs leaves it deleted on later publishes")
    func deletedOnTheTeamAsksFirst() async throws {
        let favorite = TeamLibraryFixture.favorite(name: "Orders")
        let fixture = try await TeamLibraryFixture()
        _ = try await fixture.sync.publishSavedQueries(favorites: [favorite], folders: [], to: Self.team)
        let clientID = favorite.id.uuidString.lowercased()
        await fixture.library { $0.write(Self.team, kind: "query", clientID: clientID, data: nil) }

        let result = try await fixture.sync.publishSavedQueries(favorites: [favorite], folders: [], to: Self.team)

        #expect(result == .conflicts(1))
        let asked = try #require(await fixture.pushes().last?.first)
        #expect(asked["base_version"] == nil || asked["base_version"] is NSNull)
        let conflict = try #require(fixture.sync.conflicts.first)
        #expect(fixture.sync.current(for: conflict)?.deleted == true)

        await fixture.sync.resolve(conflict, keepingMine: false)
        let again = try await fixture.sync.publishSavedQueries(favorites: [favorite], folders: [], to: Self.team)

        #expect(again == .unchanged)
        #expect(await fixture.server.library.item(Self.team, kind: "query", clientID: clientID)?.deleted == true)
    }

    nonisolated private static let conflictID = "4c6b1e2a-0d8f-4f43-9a51-7c1b2e3d4f50"

    private func conflicted() async throws -> TeamLibraryFixture {
        let id = try #require(UUID(uuidString: Self.conflictID))
        let fixture = try await TeamLibraryFixture { library in
            library.write(Self.team, kind: "query", clientID: Self.conflictID, data: TeamLibraryFixture.queryData("Orders"))
        }
        await fixture.sync.sync()
        // Another admin writes between this Mac's pull and its push: the push still says base_version 1.
        let favorite = TeamLibraryFixture.favorite(id, name: "Orders", query: "select mine")
        await fixture.library {
            $0.write(Self.team, kind: "query", clientID: Self.conflictID, data: TeamLibraryFixture.queryData("Orders", query: "select theirs"))
        }
        var state = try #require(fixture.store.loadAll().first)
        let edits = try TeamLibraryPublishPlan.savedQueries(favorites: [favorite], folders: [], in: state)
        state.pending = edits
        fixture.store.save(state)
        fixture.relaunch()
        await fixture.sync.sync()
        return fixture
    }

    // MARK: - From /v1

    @Test("The first /v2 sync takes over the /v1 cache item by item: nothing duplicated, nothing deleted")
    func legacyCacheBecomesTheFirstSync() async throws {
        let connectionID = UUID()
        let folderID = UUID()
        let queryID = UUID()
        let theirsID = UUID().uuidString.lowercased()
        let settings = ExportableConnection(name: "Prod", host: "db.internal", port: 5432, database: "app", username: "ada", type: "PostgreSQL")
        let settingsJSON = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        let fixture = try await TeamLibraryFixture { library in
            // How /v1 stores what the old build published: uuid-typed client IDs in lowercase.
            library.write(Self.team, kind: "connection", clientID: connectionID.uuidString.lowercased(), data: settingsJSON, by: "acct_test", via: "v1")
            library.write(Self.team, kind: "folder", clientID: folderID.uuidString.lowercased(), data: TeamLibraryFixture.folderData("Reports"), by: "acct_test", via: "v1")
            library.write(Self.team, kind: "query", clientID: queryID.uuidString.lowercased(), data: TeamLibraryFixture.queryData("Orders", folder: folderID.uuidString.lowercased()), by: "acct_test", via: "v1")
            library.write(Self.team, kind: "query", clientID: theirsID, data: TeamLibraryFixture.queryData("Theirs"), via: "v1")
            library.write(Self.team, kind: "query", clientID: "since", data: TeamLibraryFixture.queryData("Since"))
        }
        let cache: [String: Any] = [
            "connections": [[
                "id": "lib_01", "source_connection_id": connectionID.uuidString, "payload": settingsJSON,
                "published_by": "ada@m16.example", "published_at": "2026-10-01T09:00:00Z"
            ]],
            "query_folders": [[
                "client_id": folderID.uuidString.lowercased(), "parent_client_id": NSNull(), "name": "Reports",
                "sort_order": 0, "published_by": "ada@m16.example"
            ]],
            "queries": [
                [
                    "client_id": queryID.uuidString.lowercased(), "folder_client_id": folderID.uuidString.lowercased(),
                    "connection_client_id": NSNull(), "name": "Orders", "query": "select 1", "keyword": NSNull(),
                    "sort_order": 0, "published_by": "ada@m16.example"
                ],
                [
                    "client_id": theirsID, "folder_client_id": NSNull(), "connection_client_id": NSNull(),
                    "name": "Theirs", "query": "select 1", "keyword": NSNull(), "sort_order": 0, "published_by": "sam@m16.example"
                ]
            ],
            "fetched_at": "2026-10-28T09:00:00+00:00"
        ]
        try JSONSerialization.data(withJSONObject: cache).write(to: fixture.store.legacyFile)
        fixture.defaults.defaults.set(1_800_000_000.0, forKey: TeamLibraryStateStore.legacyPullKey)
        fixture.relaunch()

        #expect(fixture.sync.content.connections.map(\.settings.name) == ["Prod"], "The /v1 cache shows before any pull")
        #expect(fixture.sync.content.queries.map(\.name) == ["Theirs", "Orders"])
        #expect(await fixture.libraryRequests().isEmpty)

        #expect(await fixture.sync.sync() == .synced)

        #expect(fixture.sync.content.connections.map(\.id) == [connectionID.uuidString.lowercased()])
        #expect(fixture.sync.content.queries.map(\.name) == ["Since", "Theirs", "Orders"])
        #expect(!FileManager.default.fileExists(atPath: fixture.store.legacyFile.path))
        #expect(fixture.defaults.defaults.object(forKey: TeamLibraryStateStore.legacyPullKey) == nil)

        let folder = SQLFavoriteFolder(id: folderID, name: "Reports")
        let edited = TeamLibraryFixture.favorite(queryID, name: "Orders", query: "select 2", folder: folderID)
        let queries = try await fixture.sync.publishSavedQueries(favorites: [edited], folders: [folder], to: Self.team)
        var renamed = settings
        renamed.name = "Production"
        let connections = try await fixture.sync.publishConnections(
            [TeamLibraryPublishPlan.Connection(id: connectionID, settings: renamed)],
            to: Self.team
        )

        #expect(queries == .published(1))
        #expect(connections == .published(1))
        let pushed = await fixture.pushes().flatMap { $0 }
        #expect(pushed.map { $0["client_id"] as? String } == [queryID.uuidString.lowercased(), connectionID.uuidString.lowercased()])
        #expect(pushed.map { $0["base_version"] as? Int } == [1, 1])
        #expect(pushed.allSatisfy { $0["op"] as? String == "upsert" })
        let live = await fixture.server.library.live(Self.team)
        #expect(live.count == 5, "Same client IDs: the /v1 items were updated, not copied")
        #expect(fixture.sync.conflicts.isEmpty)
    }

    @Test("What this account published over /v1 is this Mac's to remove after the update; what others published is not")
    func legacyPublishedItemsAreThisMacs() async throws {
        let folderID = UUID().uuidString.lowercased()
        let queryID = UUID().uuidString.lowercased()
        let theirsID = UUID().uuidString.lowercased()
        let fixture = try await TeamLibraryFixture { library in
            library.write(Self.team, kind: "folder", clientID: folderID, data: TeamLibraryFixture.folderData("Reports"), by: "acct_test", via: "v1")
            library.write(Self.team, kind: "query", clientID: queryID, data: TeamLibraryFixture.queryData("Orders", folder: folderID), by: "acct_test", via: "v1")
            library.write(Self.team, kind: "query", clientID: theirsID, data: TeamLibraryFixture.queryData("Theirs"), via: "v1")
        }
        let cache: [String: Any] = [
            "connections": [[String: Any]](),
            "query_folders": [["client_id": folderID, "name": "Reports", "sort_order": 0, "published_by": "Ada@M16.example"]],
            "queries": [
                ["client_id": queryID, "folder_client_id": folderID, "name": "Orders", "query": "select 1", "sort_order": 0, "published_by": "ada@m16.example"],
                ["client_id": theirsID, "name": "Theirs", "query": "select 1", "sort_order": 0, "published_by": "sam@m16.example"]
            ],
            "fetched_at": "2026-10-28T09:00:00+00:00"
        ]
        try JSONSerialization.data(withJSONObject: cache).write(to: fixture.store.legacyFile)
        fixture.relaunch()
        #expect(await fixture.sync.sync() == .synced)

        // Reports and Orders are gone from this Mac; Theirs never was this Mac's.
        let result = try await fixture.sync.publishSavedQueries(favorites: [], folders: [], to: Self.team)

        #expect(result == .published(2))
        let changes = try #require(await fixture.pushes().last)
        #expect(changes.map { "\($0["op"] ?? "") \($0["kind"] ?? "") \($0["client_id"] ?? "")" } == [
            "delete query \(queryID)",
            "delete folder \(folderID)"
        ])
        #expect(await fixture.server.library.item(Self.team, kind: "query", clientID: theirsID)?.deleted == false)
    }

    @Test("A cached /v1 connection without settings is skipped, and the rest of the cache still shows")
    func legacyConnectionWithoutSettings() async throws {
        let fixture = try await TeamLibraryFixture()
        let cache: [String: Any] = [
            "connections": [["id": "lib_01", "source_connection_id": UUID().uuidString, "payload": [Any]()]],
            "query_folders": [[String: Any]](),
            "queries": [[
                "client_id": UUID().uuidString.lowercased(), "name": "Orders", "query": "select 1", "sort_order": 0
            ]],
            "fetched_at": "2026-10-28T09:00:00+00:00"
        ]
        try JSONSerialization.data(withJSONObject: cache).write(to: fixture.store.legacyFile)

        fixture.relaunch()

        #expect(fixture.sync.content.connections.isEmpty)
        #expect(fixture.sync.content.queries.map(\.name) == ["Orders"])
    }

    // MARK: - Failures

    @Test("A 429 retries after 30 seconds, then 60, then the 15-minute schedule once it answers")
    func rateLimitBacksOff() async throws {
        let fixture = try await TeamLibraryFixture { $0.faults = [429, 429] }

        fixture.sync.start()
        try await waitUntil { await fixture.pulls().count == 1 }
        await fixture.clock.waitUntilSleeping()
        #expect(fixture.sync.status == .failed(.rateLimited))

        fixture.clock.advance(by: .seconds(29))
        await fixture.clock.waitUntilSleeping()
        #expect(await fixture.pulls().count == 1)
        fixture.clock.advance(by: .seconds(1))
        try await waitUntil { await fixture.pulls().count == 2 }

        await fixture.clock.waitUntilSleeping()
        fixture.clock.advance(by: .seconds(59))
        await fixture.clock.waitUntilSleeping()
        #expect(await fixture.pulls().count == 2)
        fixture.clock.advance(by: .seconds(1))
        try await waitUntil { await fixture.pulls().count == 3 }
        try await waitUntil {
            if case .synced = fixture.sync.status { return true }
            return false
        }

        await fixture.clock.waitUntilSleeping()
        fixture.clock.advance(by: .seconds(14 * 60))
        await fixture.clock.waitUntilSleeping()
        #expect(await fixture.pulls().count == 3)
        fixture.clock.advance(by: .seconds(60))
        try await waitUntil { await fixture.pulls().count == 4 }
        fixture.sync.stop()
    }

    @Test("A 5xx during a publish keeps the edits on this Mac and the next sync pushes them")
    func serverErrorQueuesThePush() async throws {
        let fixture = try await TeamLibraryFixture()
        await fixture.sync.sync()
        await fixture.library { $0.pushFaults = [503] }

        let result = try await fixture.sync.publishSavedQueries(
            favorites: [TeamLibraryFixture.favorite(name: "Orders")],
            folders: [],
            to: Self.team
        )

        #expect(result == .queued(.server))
        #expect(fixture.sync.status == .failed(.server))
        fixture.relaunch()
        #expect(await fixture.sync.sync() == .synced)
        #expect(await fixture.server.library.live(Self.team).count == 1)
        #expect(fixture.sync.content.queries.map(\.name) == ["Orders"])
    }

    // MARK: - Who may write

    @Test("A member without the owner or admin role pulls and never pushes")
    func pullOnlyMemberNeverPushes() async throws {
        let fixture = try await TeamLibraryFixture(role: "member") { library in
            library.write(Self.team, kind: "query", clientID: "q1", data: TeamLibraryFixture.queryData("Orders"))
        }

        #expect(await fixture.sync.sync() == .synced)
        #expect(fixture.sync.content.queries.map(\.name) == ["Orders"])
        #expect(!fixture.sync.canPublish)

        await #expect(throws: TeamLibraryPublishError.notWritable) {
            try await fixture.sync.publishSavedQueries(
                favorites: [TeamLibraryFixture.favorite(name: "Mine")],
                folders: [],
                to: Self.team
            )
        }
        #expect(await fixture.pushes().isEmpty)
    }

    @Test("Edits stored while this account could write are dropped once it only reads")
    func demotedWriterDropsItsEdits() async throws {
        let fixture = try await TeamLibraryFixture()
        await fixture.sync.sync()
        var state = try #require(fixture.store.loadAll().first)
        state.pending = try TeamLibraryPublishPlan.savedQueries(
            favorites: [TeamLibraryFixture.favorite(name: "Mine")],
            folders: [],
            in: state
        )
        fixture.store.save(state)
        await fixture.server.set {
            $0.memberships = [FakeAccountServer.membership(teamID: Self.team, name: "Acme", role: "member", hasSeat: true)]
        }
        fixture.relaunch()

        #expect(await fixture.sync.sync() == .synced)

        #expect(await fixture.pushes().isEmpty)
        #expect(fixture.store.loadAll().first?.pending.isEmpty == true)
    }

    @Test("A team the account lost its seat in is dropped with what it held")
    func lostSeatDropsTheTeam() async throws {
        let fixture = try await TeamLibraryFixture { library in
            library.write(Self.team, kind: "query", clientID: "q1", data: TeamLibraryFixture.queryData("Orders"))
        }
        await fixture.sync.sync()
        await fixture.server.set {
            $0.memberships = [FakeAccountServer.membership(teamID: Self.team, name: "Acme", role: "owner", hasSeat: false)]
        }

        await fixture.sync.sync()

        #expect(fixture.sync.content == .empty)
        #expect(fixture.store.loadAll().isEmpty)
    }

    @Test("Signing out drops every team's library")
    func signOutClears() async throws {
        let fixture = try await TeamLibraryFixture { library in
            library.write(Self.team, kind: "query", clientID: "q1", data: TeamLibraryFixture.queryData("Orders"))
        }
        fixture.sync.start()
        try await waitUntil { !fixture.sync.content.queries.isEmpty }

        await fixture.account.services.signOut()

        try await waitUntil { fixture.sync.content == .empty }
        #expect(fixture.store.loadAll().isEmpty)
        fixture.sync.stop()
    }
}
