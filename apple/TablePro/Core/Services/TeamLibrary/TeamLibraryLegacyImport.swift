//
//  TeamLibraryLegacyImport.swift
//  TablePro
//

import CryptoKit
import Foundation
import os
import TableProFFI

// What earlier builds kept of Team Library, handed once to the core (core ADR 0054, The offline queue is on disk):
// - 0.88 and earlier: one file per team with its unsent edits, what this Mac published and what Keep Theirs turned
//   down, read only for the tablepro.app sign-in the core restores at launch. The owner it is read for is written and
//   read back before the first read, so no other sign-in ever reads it; any other sign-in, a company server and a
//   launch signed out delete it unread. Its files stay until the core has taken them, for that owner's next launch.
// - 0.89: a read cache per server and account, whose only state this Mac alone held is what it published. The
//   current owner's goes to the core; every other one goes with it, as another owner's data does at a sign-in.
// - The /v1 cache the library kept before /v2 holds nothing an import can place in a team, and is deleted.
internal struct TeamLibraryLegacyImport {
    private static let logger = Logger(subsystem: "com.TablePro", category: "TeamLibraryLegacyImport")
    // 0.89 sets it once it read the 0.88 store.
    static let consideredKey = "com.TablePro.teamLibrary.earlierLibraryConsidered"
    static let ownerKey = "com.TablePro.teamLibrary.earlierLibraryOwner"

    let flatDirectory: URL
    let legacyFile: URL
    let cacheRoot: URL
    let defaults: UserDefaults

    static func live() -> TeamLibraryLegacyImport {
        let environment = AppStorageEnvironment.shared
        let support = environment.supportDirectory
        return TeamLibraryLegacyImport(
            flatDirectory: support.appendingPathComponent("TeamLibrary", isDirectory: true),
            legacyFile: support.appendingPathComponent("team_library.json"),
            cacheRoot: support.appendingPathComponent("TeamLibraryCache", isDirectory: true),
            defaults: environment.defaults
        )
    }

    // What to import for this owner's sign-in; empty when there is nothing, or nothing it may read. Nil when a file
    // could not be read, which keeps every file for the owner's next launch: a store is deleted only once the core holds
    // all of it.
    func take(for owner: TeamLibraryOwnerArg, restoredAtLaunch: Bool, isProduction: Bool) -> [TeamLibraryImportArg]? {
        removeOtherCaches(keeping: owner)
        try? FileManager.default.removeItem(at: legacyFile)
        var teams: [String: TeamLibraryImportArg] = [:]
        if hasFlat, claimFlat(for: owner, restoredAtLaunch: restoredAtLaunch, isProduction: isProduction) {
            guard let flat = Self.read(flatDirectory, withEdits: true, owner: owner) else { return nil }
            for team in flat {
                teams[team.teamId] = team
            }
        }
        let cache = cacheFolder(for: owner).appendingPathComponent("Teams", isDirectory: true)
        guard let cached = Self.read(cache, withEdits: false, owner: owner) else { return nil }
        for team in cached {
            teams[team.teamId] = Self.merged(teams[team.teamId], team)
        }
        return teams.values.sorted { $0.teamId < $1.teamId }
    }

    // The core holds them now.
    func imported(for owner: TeamLibraryOwnerArg) {
        try? FileManager.default.removeItem(at: flatDirectory)
        try? FileManager.default.removeItem(at: cacheFolder(for: owner))
        defaults.set(true, forKey: Self.consideredKey)
        defaults.removeObject(forKey: Self.ownerKey)
    }

    // MARK: - 0.88

    private var hasFlat: Bool {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: flatDirectory.path)) ?? []
        return !files.isEmpty
    }

    // True when this owner may read the store now. The owner is decided once, at the first launch that meets it.
    private func claimFlat(for owner: TeamLibraryOwnerArg, restoredAtLaunch: Bool, isProduction: Bool) -> Bool {
        let name = Self.ownerName(owner)
        if defaults.bool(forKey: Self.consideredKey) {
            removeFlat()
            return false
        }
        if let claimed = defaults.string(forKey: Self.ownerKey) {
            guard claimed == name else {
                markConsidered()
                return false
            }
            return true
        }
        guard restoredAtLaunch, isProduction else {
            markConsidered()
            return false
        }
        defaults.set(name, forKey: Self.ownerKey)
        // The owner reaches cfprefsd before the store is read, so a crash after the read cannot hand it to another.
        guard defaults.synchronize(), defaults.string(forKey: Self.ownerKey) == name else {
            Self.logger.error("The owner of the earlier Team Library did not stick; deleting it unread")
            markConsidered()
            return false
        }
        return true
    }

    // Unread, for good.
    private func markConsidered() {
        defaults.set(true, forKey: Self.consideredKey)
        defaults.removeObject(forKey: Self.ownerKey)
        removeFlat()
    }

    private func removeFlat() {
        try? FileManager.default.removeItem(at: flatDirectory)
    }

    // Every team file in `directory`. A file that names an owner, as development builds of the account move wrote, is
    // read only for that owner. One that is not JSON never will be and is skipped; one that cannot be read is nil.
    private static func read(_ directory: URL, withEdits: Bool, owner: TeamLibraryOwnerArg) -> [TeamLibraryImportArg]? {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch {
            logger.error("The earlier Team Library folder is unreadable: \(error.publicLogShape, privacy: .public)")
            return nil
        }
        var teams: [TeamLibraryImportArg] = []
        for file in files where file.pathExtension == "json" {
            let data: Data
            do {
                data = try Data(contentsOf: file)
            } catch {
                logger.error("An earlier Team Library file is unreadable: \(error.publicLogShape, privacy: .public)")
                return nil
            }
            guard let team = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                logger.error("Skipping an earlier Team Library file that is not JSON")
                continue
            }
            guard belongs(team, to: owner), let read = Self.team(from: team, withEdits: withEdits) else { continue }
            teams.append(read)
        }
        return teams
    }

    private static func belongs(_ team: [String: Any], to owner: TeamLibraryOwnerArg) -> Bool {
        guard let named = team["owner"] else { return true }
        guard let named = named as? [String: Any],
              let server = named["server"] as? String,
              let account = named["accountID"] as? String
        else { return false }
        return server == owner.apiOrigin && account == owner.accountId
    }

    // MARK: - 0.89

    private func cacheFolder(for owner: TeamLibraryOwnerArg) -> URL {
        let digest = SHA256.hash(data: Data("\(owner.apiOrigin)\n\(owner.accountId)".utf8))
        return cacheRoot.appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined(), isDirectory: true)
    }

    private func removeOtherCaches(keeping owner: TeamLibraryOwnerArg) {
        let kept = cacheFolder(for: owner).lastPathComponent
        let folders = (try? FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where folder.lastPathComponent != kept {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: - Reading a team

    // A team file as both builds wrote it: items and edits in the facade's shape (client_id, kind, version, data, op,
    // base_version), keys as kind and clientID.
    private static func team(from team: [String: Any], withEdits: Bool) -> TeamLibraryImportArg? {
        guard let teamID = team["teamID"] as? String else { return nil }
        let items = (team["items"] as? [[String: Any]]) ?? []
        let moves = Set(((team["moves"] as? [[String: Any]]) ?? []).compactMap(reference(key:)))
        var edits: [TeamImportedEditArg] = []
        if withEdits {
            let pending = (team["pending"] as? [[String: Any]]) ?? []
            let conflicted = ((team["conflicts"] as? [[String: Any]]) ?? []).compactMap { $0["edit"] as? [String: Any] }
            edits = (pending + conflicted).compactMap { edit(from: $0, items: items, moves: moves) }
        }
        let published = ((team["published"] as? [[String: Any]]) ?? []).compactMap(reference(key:))
        let declined: [TeamDeclinedArg] = withEdits
            ? ((team["declined"] as? [[String: Any]]) ?? []).compactMap { entry in
                guard let key = entry["key"] as? [String: Any], let item = reference(key: key),
                      let data = entry["data"] as? [String: Any], let fields = json(data)
                else { return nil }
                return TeamDeclinedArg(item: item, fieldsJson: fields)
            }
            : []
        guard !edits.isEmpty || !published.isEmpty || !declined.isEmpty else { return nil }
        return TeamLibraryImportArg(teamId: teamID, edits: edits, published: published, declined: declined)
    }

    private static func edit(
        from edit: [String: Any],
        items: [[String: Any]],
        moves: Set<TeamLibraryItemRef>
    ) -> TeamImportedEditArg? {
        guard let kindName = edit["kind"] as? String, let kind = kind(kindName),
              let id = edit["client_id"] as? String, !id.isEmpty
        else { return nil }
        let item = TeamLibraryItemRef(kind: kind, id: id)
        let baseVersion = (edit["base_version"] as? NSNumber).map(\.uint64Value)
        let base = baseVersion.flatMap { version in
            items.first { held in
                (held["kind"] as? String) == kindName
                    && (held["client_id"] as? String)?.lowercased() == id.lowercased()
                    && (held["version"] as? NSNumber)?.uint64Value == version
                    && (held["deleted"] as? Bool) != true
            }
        }
        let deletes = (edit["op"] as? String) == "delete"
        return TeamImportedEditArg(
            item: item,
            baseVersion: baseVersion,
            baseFieldsJson: (base?["data"] as? [String: Any]).flatMap(json),
            fieldsJson: deletes ? nil : json((edit["data"] as? [String: Any]) ?? [:]),
            moved: moves.contains(where: { $0.kind == kind && $0.id.lowercased() == id.lowercased() })
        )
    }

    private static func reference(key: [String: Any]) -> TeamLibraryItemRef? {
        guard let kindName = key["kind"] as? String, let kind = kind(kindName),
              let id = key["clientID"] as? String, !id.isEmpty
        else { return nil }
        return TeamLibraryItemRef(kind: kind, id: id)
    }

    private static func kind(_ name: String) -> TeamLibraryKindTag? {
        switch name {
        case "connection": .connection
        case "folder": .folder
        case "query": .query
        default: nil
        }
    }

    private static func json(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func merged(_ flat: TeamLibraryImportArg?, _ cache: TeamLibraryImportArg) -> TeamLibraryImportArg {
        guard let flat else { return cache }
        let published = flat.published + cache.published.filter { item in !flat.published.contains(item) }
        return TeamLibraryImportArg(teamId: flat.teamId, edits: flat.edits, published: published, declined: flat.declined)
    }

    private static func ownerName(_ owner: TeamLibraryOwnerArg) -> String {
        "\(owner.apiOrigin)\n\(owner.accountId)"
    }
}
