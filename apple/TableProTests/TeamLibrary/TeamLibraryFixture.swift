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
    let store: TeamLibraryStateStore
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
        store = TeamLibraryStateStore(
            directory: directory.appendingPathComponent("TeamLibrary", isDirectory: true),
            legacyFile: directory.appendingPathComponent("team_library.json"),
            defaults: defaults.defaults
        )
        sync = TeamLibrarySync(account: account.services, store: store, clock: clock)
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
        sync = TeamLibrarySync(account: account.services, store: store, clock: clock)
        sync.loadIfNeeded()
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
