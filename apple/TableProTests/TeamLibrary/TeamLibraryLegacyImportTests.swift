//
//  TeamLibraryLegacyImportTests.swift
//  TableProTests
//

import CryptoKit
import Foundation
@testable import TablePro
import TableProFFI
import TableProTestSupport
import Testing

@MainActor
struct TeamLibraryLegacyImportTests {
    // A team file as 0.88 and earlier wrote it: one unsent edit against version 3, one that conflicted, a move, what it
    // published and what Keep Theirs turned down.
    private static func flatTeam(owner: [String: Any]? = nil) -> [String: Any] {
        var team: [String: Any] = [
            "teamID": TeamLibraryFixture.team,
            "teamName": "Acme",
            "canWrite": true,
            "items": [
                ["client_id": "Q1", "kind": "query", "version": 3, "deleted": false, "updated_at": "2026-10-01T00:00:00Z",
                 "data": ["name": "Orders", "query": "select 1", "sort_order": 0]]
            ],
            "pending": [
                ["base_version": 3, "client_id": "Q1", "kind": "query", "op": "upsert",
                 "data": ["name": "Orders", "query": "select 2", "sort_order": 0]],
                ["client_id": "f1", "kind": "folder", "op": "delete"]
            ],
            "conflicts": [
                ["id": UUID().uuidString, "teamID": TeamLibraryFixture.team,
                 "edit": ["base_version": 1, "client_id": "q2", "kind": "query", "op": "upsert",
                          "data": ["name": "Moved", "query": "select 3", "folder_client_id": "f0", "sort_order": 1]]]
            ],
            "published": [["kind": "query", "clientID": "q1"]],
            "moves": [["kind": "query", "clientID": "q2"]],
            "declined": [["key": ["kind": "query", "clientID": "q9"], "data": ["name": "Theirs", "query": "select 9", "sort_order": 0]]]
        ]
        if let owner {
            team["owner"] = owner
        }
        return team
    }

    private static func writeFlat(_ team: [String: Any], in fixture: TeamLibraryFixture) throws {
        let directory = fixture.legacy.flatDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: team).write(to: directory.appendingPathComponent("acme.json"))
    }

    private static func cacheFolder(_ origin: String, _ account: String, in fixture: TeamLibraryFixture) -> URL {
        let digest = SHA256.hash(data: Data("\(origin)\n\(account)".utf8))
        return fixture.legacy.cacheRoot.appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined(), isDirectory: true)
    }

    // A team file of 0.89's read cache, which kept only what the team holds and what this Mac published.
    private static func writeCache(published: [[String: Any]], for account: String, in fixture: TeamLibraryFixture) throws -> URL {
        let folder = cacheFolder(TeamLibraryFixture.owner.apiOrigin, account, in: fixture)
        let teams = folder.appendingPathComponent("Teams", isDirectory: true)
        try FileManager.default.createDirectory(at: teams, withIntermediateDirectories: true)
        let team: [String: Any] = [
            "teamID": TeamLibraryFixture.team, "teamName": "Acme", "canWrite": true, "items": [], "pending": [],
            "conflicts": [], "published": published, "moves": [], "declined": []
        ]
        try JSONSerialization.data(withJSONObject: team).write(to: teams.appendingPathComponent("acme.json"))
        return folder
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    @Test("The library 0.88 kept goes to the core once for the sign-in restored at launch: edits on their base, published, declined")
    func flatStoreIsImportedOnce() async throws {
        let fixture = try await TeamLibraryFixture()
        try Self.writeFlat(Self.flatTeam(), in: fixture)

        try await fixture.start()
        try await waitUntil { !fixture.engine.imports.isEmpty }

        let team = try #require(fixture.engine.imports.first?.first)
        #expect(team.teamId == TeamLibraryFixture.team)
        let update = try #require(team.edits.first { $0.item.id == "Q1" })
        #expect(update.baseVersion == 3)
        #expect(TeamLibraryFixture.object(update.baseFieldsJson)?["query"] as? String == "select 1")
        #expect(TeamLibraryFixture.object(update.fieldsJson)?["query"] as? String == "select 2")
        #expect(!update.moved)
        let deletion = try #require(team.edits.first { $0.item.id == "f1" })
        #expect(deletion.fieldsJson == nil && deletion.baseVersion == nil)
        let conflicted = try #require(team.edits.first { $0.item.id == "q2" })
        #expect(conflicted.moved)
        #expect(conflicted.baseFieldsJson == nil, "The team's copy is at another version than the edit's base")
        #expect(team.published == [TeamLibraryItemRef(kind: .query, id: "q1")])
        #expect(team.declined.map { $0.item } == [TeamLibraryItemRef(kind: .query, id: "q9")])
        try await waitUntil { !Self.exists(fixture.legacy.flatDirectory) }

        fixture.relaunch()
        try await fixture.start()
        #expect(fixture.engine.imports.count == 1)
    }

    @Test("A store the core could not take yet stays for the same account's next launch, and is read then")
    func failedImportIsTriedAgain() async throws {
        let fixture = try await TeamLibraryFixture()
        try Self.writeFlat(Self.flatTeam(), in: fixture)
        fixture.engine.failImports(with: TeamConflictFixture.failure("sync.state.io"))

        try await fixture.start()
        try await waitUntil { fixture.defaults.defaults.string(forKey: TeamLibraryLegacyImport.ownerKey) != nil }
        #expect(Self.exists(fixture.legacy.flatDirectory))

        fixture.engine.failImports(with: nil)
        fixture.relaunch()
        try await fixture.start()

        try await waitUntil { fixture.engine.imports.count == 1 }
        try await waitUntil { !Self.exists(fixture.legacy.flatDirectory) }
    }

    @Test("A sign-in made in this run, a company server or another account never reads the library 0.88 kept")
    func flatStoreIsDeletedUnreadForOthers() async throws {
        let fixture = try await TeamLibraryFixture(signedIn: false)
        try Self.writeFlat(Self.flatTeam(), in: fixture)
        fixture.account.services.loadStoredState()
        try await waitUntil { fixture.account.access.state.isRestored }
        try await fixture.start()

        try await fixture.account.signIn()

        try await waitUntil { !Self.exists(fixture.legacy.flatDirectory) }
        #expect(fixture.engine.imports.isEmpty)
        #expect(fixture.defaults.defaults.bool(forKey: TeamLibraryLegacyImport.consideredKey))
    }

    @Test("A file that names another account goes unread, and the store goes with it")
    func ownedFileIsReadOnlyForItsOwner() async throws {
        let fixture = try await TeamLibraryFixture()
        let other = ["server": TeamLibraryFixture.owner.apiOrigin, "accountID": "acct_other"]
        try Self.writeFlat(Self.flatTeam(owner: other), in: fixture)

        try await fixture.start()

        try await waitUntil { !Self.exists(fixture.legacy.flatDirectory) }
        #expect(fixture.engine.imports.isEmpty)
    }

    @Test("A file that cannot be read keeps the whole store for the next launch, and nothing goes to the core")
    func unreadableFileKeepsTheStore() async throws {
        let fixture = try await TeamLibraryFixture()
        try Self.writeFlat(Self.flatTeam(), in: fixture)
        let file = fixture.legacy.flatDirectory.appendingPathComponent("acme.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }

        try await fixture.start()
        try await waitUntil { fixture.defaults.defaults.string(forKey: TeamLibraryLegacyImport.ownerKey) != nil }
        await fixture.library.refresh()

        #expect(fixture.engine.imports.isEmpty)
        #expect(Self.exists(file))
    }

    @Test("Another account's sign-in while the store is being taken imports nothing of it into that account")
    func switchDuringAdoptionImportsNothing() async throws {
        let fixture = try await TeamLibraryFixture()
        try Self.writeFlat(Self.flatTeam(), in: fixture)
        let gate = AsyncGate()
        fixture.source.deleteOthersGate = gate

        fixture.library.start()
        await gate.arrived(1)
        try await fixture.refuseRefresh()
        await fixture.account.server.set { $0.accountID = "acct_other" }
        try await fixture.account.signIn()
        await gate.open()

        try await waitUntil { fixture.source.keptOwners.count == 2 }
        try await waitUntil { !Self.exists(fixture.legacy.flatDirectory) }
        #expect(fixture.engine.imports.isEmpty)
    }

    @Test("Sign Out after an import the core could not take deletes the earlier files and their claim")
    func signOutDeletesKeptEarlierFiles() async throws {
        let fixture = try await TeamLibraryFixture()
        try Self.writeFlat(Self.flatTeam(), in: fixture)
        let cache = try Self.writeCache(published: [["kind": "folder", "clientID": "f1"]], for: "acct_test", in: fixture)
        fixture.engine.failImports(with: TeamConflictFixture.failure("sync.state.io"))
        try await fixture.start()
        try await waitUntil { fixture.defaults.defaults.string(forKey: TeamLibraryLegacyImport.ownerKey) != nil }

        let deleted = await fixture.library.signOut(session: fixture.account.access.state.sessionID) {
            [services = fixture.account.services] in await services.signOut()
        }

        #expect(deleted == true)
        #expect(!Self.exists(fixture.legacy.flatDirectory))
        #expect(!Self.exists(cache))
        #expect(fixture.defaults.defaults.string(forKey: TeamLibraryLegacyImport.ownerKey) == nil)
        #expect(fixture.defaults.defaults.bool(forKey: TeamLibraryLegacyImport.consideredKey))
    }

    @Test("A 0.88 folder that cannot be listed decides nothing, and is read once it can be")
    func unlistableFolderDecidesNothing() async throws {
        let fixture = try await TeamLibraryFixture()
        try Self.writeFlat(Self.flatTeam(), in: fixture)
        let folder = fixture.legacy.flatDirectory
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        try await fixture.start()

        #expect(fixture.engine.imports.isEmpty)
        #expect(!fixture.defaults.defaults.bool(forKey: TeamLibraryLegacyImport.consideredKey))
        #expect(fixture.defaults.defaults.string(forKey: TeamLibraryLegacyImport.ownerKey) == nil)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        fixture.relaunch()
        try await fixture.start()

        try await waitUntil { fixture.engine.imports.count == 1 }
    }

    @Test("Once 0.89 read the store, it is never read again")
    func consideredStoreIsNeverRead() async throws {
        let fixture = try await TeamLibraryFixture()
        fixture.defaults.defaults.set(true, forKey: TeamLibraryLegacyImport.consideredKey)
        try Self.writeFlat(Self.flatTeam(), in: fixture)

        try await fixture.start()

        try await waitUntil { !Self.exists(fixture.legacy.flatDirectory) }
        #expect(fixture.engine.imports.isEmpty)
    }

    @Test("0.89's cache gives the core what this Mac published, and every other account's cache goes")
    func cacheGivesWhatThisMacPublished() async throws {
        let fixture = try await TeamLibraryFixture()
        let mine = try Self.writeCache(published: [["kind": "folder", "clientID": "f1"]], for: "acct_test", in: fixture)
        let theirs = try Self.writeCache(published: [["kind": "query", "clientID": "q7"]], for: "acct_other", in: fixture)

        try await fixture.start()
        try await waitUntil { !fixture.engine.imports.isEmpty }

        let team = try #require(fixture.engine.imports.first?.first)
        #expect(team.edits.isEmpty)
        #expect(team.published == [TeamLibraryItemRef(kind: .folder, id: "f1")])
        try await waitUntil { !Self.exists(mine) && !Self.exists(theirs) }
    }
}
