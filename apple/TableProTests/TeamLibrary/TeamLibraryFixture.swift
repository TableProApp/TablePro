//
//  TeamLibraryFixture.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProCloudAPI
import TableProTestSupport

// A signed-in account with the team_library feature, a seat in one team, and a sync engine storing into a temporary
// folder, against FakeAccountServer's library.
@MainActor
final class TeamLibraryFixture {
    nonisolated static let team = "team_01jbvh7pn9e3sv4bzq4rqk4kzh"

    let account: AccountFixture
    let defaults: EphemeralDefaults
    let directory: URL
    let clock = ManualClock()
    let storage: TeamLibraryStorage
    // The read cache of the account the fixture signs in.
    let store: TeamLibraryStateStore
    // What each involuntary sign-out discarded.
    let discarded = DiscardedLog()
    // What each one-time upload of the edits 0.88 left could not get taken.
    let notTaken = DiscardedLog()
    private(set) var sync: TeamLibrarySync

    init(role: String = "owner", hasSeat: Bool = true, seed: (inout FakeTeamLibrary) -> Void = { _ in }) async throws {
        account = try AccountFixture()
        var library = FakeTeamLibrary()
        seed(&library)
        let seeded = library
        await account.server.set {
            $0.features = ["team_library"]
            $0.memberships = [FakeAccountServer.membership(teamID: Self.team, name: "Acme", role: role, hasSeat: hasSeat)]
            $0.library = seeded
        }
        try await account.signIn()
        defaults = try EphemeralDefaults()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TeamLibraryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storage = TeamLibraryStorage(
            flat: TeamLibraryStateStore(
                directory: directory.appendingPathComponent("TeamLibrary", isDirectory: true),
                legacyFile: directory.appendingPathComponent("team_library.json"),
                defaults: defaults.defaults
            ),
            cacheRoot: directory.appendingPathComponent("TeamLibraryCache", isDirectory: true),
            defaults: defaults.defaults
        )
        store = storage.cache(in: storage.folder(server: AccountServer.production.apiOrigin, accountID: "acct_test"))
        sync = TeamLibrarySync(
            account: account.services, storage: storage, clock: clock,
            reportDiscarded: discarded.record, reportEarlierEditsNotTaken: notTaken.record
        )
        sync.loadIfNeeded()
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    var server: FakeAccountServer {
        account.server
    }

    // A new launch reading what the last one stored.
    func relaunch() {
        sync.stop()
        sync = TeamLibrarySync(
            account: account.services, storage: storage, clock: clock,
            reportDiscarded: discarded.record, reportEarlierEditsNotTaken: notTaken.record
        )
        sync.loadIfNeeded()
    }

    // A team file as 0.88 and earlier wrote it, unsent edits and conflicts included, on a Mac that has not read it yet.
    func writeFlat(_ state: TeamLibraryTeamState) throws {
        try JSONFileStore<TeamLibraryTeamState>(url: storage.flat.directory.appendingPathComponent("\(state.teamID).json"))
            .write(state)
        defaults.defaults.removeObject(forKey: TeamLibraryStorage.flatConsideredKey)
    }

    // The /v1 cache as 0.88 and earlier kept it, on a Mac that has not read it yet.
    func writeFlatLegacyCache(_ cache: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: cache).write(to: storage.flat.legacyFile)
        defaults.defaults.removeObject(forKey: TeamLibraryStorage.flatConsideredKey)
    }

    // The folders of the read cache on disk, one per server and account.
    var cacheFolders: [String] {
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: storage.cacheRoot.path)) ?? []
        return folders.sorted()
    }

    func library(_ change: @escaping @Sendable (inout FakeTeamLibrary) -> Void) async {
        await server.set { change(&$0.library) }
    }

    func libraryRequests() async -> [FakeAccountServer.Request] {
        await server.requests.filter { $0.path.hasPrefix("/teams/") }
    }

    func pulls() async -> [FakeAccountServer.Request] {
        await libraryRequests().filter { $0.method == "GET" }
    }

    func pushes() async -> [[[String: Any]]] {
        await libraryRequests().filter { $0.method == "POST" }.map(Self.changes)
    }

    nonisolated static func cursor(of request: FakeAccountServer.Request) -> String? {
        URLComponents(string: "http://fake\(request.path)")?.queryItems?.first { $0.name == "cursor" }?.value
    }

    nonisolated static func changes(of request: FakeAccountServer.Request) -> [[String: Any]] {
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
        return body?["changes"] as? [[String: Any]] ?? []
    }

    nonisolated static func favorite(
        _ id: UUID = UUID(),
        name: String,
        query: String = "select 1",
        folder: UUID? = nil,
        connection: UUID? = nil,
        sortOrder: Int = 0
    ) -> SQLFavorite {
        SQLFavorite(id: id, name: name, query: query, folderId: folder, connectionId: connection, sortOrder: sortOrder)
    }

    nonisolated static func queryData(_ name: String, query: String = "select 1", folder: String? = nil) -> [String: Any] {
        var data: [String: Any] = ["name": name, "query": query, "sort_order": 0]
        if let folder {
            data["folder_client_id"] = folder
        }
        return data
    }

    nonisolated static func folderData(_ name: String, parent: String? = nil) -> [String: Any] {
        var data: [String: Any] = ["name": name, "sort_order": 0]
        if let parent {
            data["parent_client_id"] = parent
        }
        return data
    }
}

@MainActor
final class DiscardedLog {
    private(set) var reports: [[String]] = []

    func record(_ changes: [String]) {
        reports.append(changes)
    }
}

// Defaults whose writes never reach the disk, as when synchronize fails.
final class UnsavedDefaults: UserDefaults {
    override func synchronize() -> Bool {
        false
    }
}
