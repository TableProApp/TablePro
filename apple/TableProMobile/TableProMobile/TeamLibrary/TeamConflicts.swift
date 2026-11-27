import Foundation
import Observation
import os
import TableProFFI

nonisolated struct TeamConflictFailure: Equatable, Sendable {
    let record: SyncRecordRef
    let message: String
}

// The team records whose fields this device and the team both changed, as the engine holds them until the person keeps
// one side. Decide Later only closes the sheet: the engine keeps both sides, and a later pull merges against them. The
// Team Library refreshes it with its own reads and ends it with the sign-in, so no conflict of an ended sign-in shows.
@MainActor @Observable
final class TeamConflictsModel {
    private static let logger = Logger(subsystem: "com.TablePro", category: "TeamLibraryConflicts")

    private(set) var conflicts: [TeamConflictInfo] = []
    private(set) var teamNames: [String: String] = [:]
    // Who last changed the team's copy of each record, by `writerKey`.
    private(set) var writers: [String: String] = [:]
    private(set) var resolving: SyncRecordRef?
    private(set) var failure: TeamConflictFailure?

    @ObservationIgnored private let engine: @MainActor () async throws -> any TeamConflictCalls
    // Each fetch, each choice and each end takes the next one, so an answer that started before the latest changes
    // nothing.
    @ObservationIgnored private var generation = 0
    // Each end of a sign-in takes the next one: a choice still out when it ends changes nothing after.
    @ObservationIgnored private var epoch = 0

    init(engine: @escaping @MainActor () async throws -> any TeamConflictCalls) {
        self.engine = engine
    }

    func name(_ teams: [String: String], writers: [String: String]) {
        if teams != teamNames {
            teamNames = teams
        }
        if writers != self.writers {
            self.writers = writers
        }
    }

    nonisolated static func writerKey(scope: String, kind: String, id: String) -> String {
        "\(scope)\n\(kind)\n\(id.lowercased())"
    }

    nonisolated static func wireKind(_ kind: TeamLibraryKindTag) -> String {
        switch kind {
        case .connection: "library_connection"
        case .folder: "library_folder"
        case .query: "library_query"
        }
    }

    func writer(of record: SyncRecordRef) -> String? {
        writers[Self.writerKey(scope: record.scope, kind: record.kind, id: record.recordId)]
    }

    func teamName(of scope: String) -> String? {
        teamNames[scope]
    }

    func failure(for record: SyncRecordRef) -> String? {
        failure?.record == record ? failure?.message : nil
    }

    // The sign-in ended: nothing of it shows from here on.
    func end() {
        generation += 1
        epoch += 1
        conflicts = []
        teamNames = [:]
        writers = [:]
        failure = nil
    }

    // A failed read keeps the conflicts already shown.
    func refresh() async {
        generation += 1
        let started = generation
        let read: [TeamConflictInfo]
        do {
            read = try await engine().conflicts()
        } catch {
            TeamLibraryLog.failure(Self.logger, "Reading team conflicts failed", error)
            return
        }
        guard started == generation else { return }
        if read != conflicts {
            conflicts = read
        }
        if let failure, !read.contains(where: { $0.record == failure.record }) {
            self.failure = nil
        }
    }

    // The choice carries the digest of the conflict shown: one a pull has replaced since is refused, and the
    // replacement is shown instead, so a choice never keeps a version the person did not see.
    func resolve(_ conflict: TeamConflictInfo, keep: ConflictChoiceTag) async {
        guard resolving == nil else { return }
        resolving = conflict.record
        defer { resolving = nil }
        let epoch = epoch
        do {
            let engine = try await engine()
            guard epoch == self.epoch else { return }
            try await engine.resolveConflict(record: conflict.record, digest: conflict.digest, keep: keep)
        } catch where Self.code(of: error) == "sync.unknown" {
            Self.logger.notice("A team conflict was settled before the choice reached it")
        } catch where Self.code(of: error) == "sync.changed" {
            guard epoch == self.epoch else { return }
            await refresh()
            failure = TeamConflictFailure(
                record: conflict.record,
                message: String(localized: "This item changed again. Review the new version, then choose.")
            )
            return
        } catch {
            TeamLibraryLog.failure(Self.logger, "Resolving a team conflict failed", error)
            guard epoch == self.epoch else { return }
            failure = TeamConflictFailure(
                record: conflict.record,
                message: String(localized: "TablePro couldn't save your choice. Try again.")
            )
            return
        }
        guard epoch == self.epoch else { return }
        generation += 1
        conflicts.removeAll { $0.record == conflict.record }
        if failure?.record == conflict.record {
            failure = nil
        }
        await refresh()
    }

    nonisolated private static func code(of error: any Error) -> String? {
        if case .Failed(let info)? = error as? CoreError {
            return info.code
        }
        return nil
    }
}

// One team conflict as the sheet shows it: only the fields both sides changed, or, against a deletion, the fields the
// side that kept the item changed.
nonisolated struct TeamConflictPresentation: Equatable, Sendable {
    enum Shape: Equatable, Sendable {
        case bothChanged
        case youDeleted
        case teamDeleted
    }

    enum Value: Equatable, Sendable {
        case text(String)
        case code(String)
        case empty
        case notSet
    }

    struct Row: Equatable, Identifiable, Sendable {
        let field: String
        let label: String
        let mine: Value?
        let theirs: Value?

        var id: String { field }
    }

    let shape: Shape
    let title: String
    let message: String
    let rows: [Row]
    // Who last changed or deleted the team's copy; none when the server names no one to this account.
    let writer: String?

    init(conflict: TeamConflictInfo, teamName: String?, writer: String? = nil) {
        let mine = conflict.mine.map(Self.members)
        let theirs = conflict.theirs.map(Self.members)
        let name = TeamLibraryVisibleText.name(
            Self.text(mine?["name"]) ?? Self.text(theirs?["name"]) ?? conflict.record.recordId
        )
        let team = teamName.map(TeamLibraryVisibleText.name) ?? String(localized: "your team")
        self.writer = writer
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : TeamLibraryVisibleText.name($0) }
        switch (mine, theirs) {
        case (nil, _):
            shape = .youDeleted
            title = String(format: String(localized: "“%@” changed after you deleted it"), name)
            message = String(
                format: String(localized: "Someone in %@ changed this item after you deleted it. Keep Mine deletes it, and Keep Theirs keeps the team's version."),
                team
            )
        case (_, nil):
            shape = .teamDeleted
            title = String(format: String(localized: "“%@” was deleted from the team library"), name)
            message = String(
                format: String(localized: "Someone in %@ deleted this item after you changed it. Keep Mine puts it back with your changes, and Keep Theirs leaves it deleted."),
                team
            )
        default:
            shape = .bothChanged
            title = String(format: String(localized: "“%@” changed since you last synced"), name)
            message = String(
                format: String(localized: "You and someone in %@ changed the same fields of this item. Choose the version the team library keeps."),
                team
            )
        }
        let kind = conflict.record.kind
        rows = Self.ordered(conflict.fields, kind: kind).map { field in
            Row(
                field: field,
                label: Self.label(of: field, kind: kind),
                mine: mine.map { Self.value(of: field, in: $0, kind: kind) },
                theirs: theirs.map { Self.value(of: field, in: $0, kind: kind) }
            )
        }
    }

    var keepMineHint: String {
        switch shape {
        case .bothChanged: String(localized: "Replaces the team's version with yours")
        case .youDeleted: String(localized: "Deletes the item from the team library")
        case .teamDeleted: String(localized: "Puts the item back with your changes")
        }
    }

    var keepTheirsHint: String {
        switch shape {
        case .bothChanged, .youDeleted: String(localized: "Leaves the team's version as it is")
        case .teamDeleted: String(localized: "Leaves the item deleted")
        }
    }

    static func spoken(_ value: Value) -> String {
        switch value {
        case .text(let text), .code(let text): text
        case .empty: String(localized: "Empty")
        case .notSet: String(localized: "Not set")
        }
    }

    // The engine sends each side as the record's JSON object; anything else reads as an item with no fields.
    private static func members(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private static func text(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    private static func value(of field: String, in members: [String: Any], kind: String) -> Value {
        guard let value = members[field], !(value is NSNull) else { return .notSet }
        if let text = value as? String {
            if text.isEmpty { return .empty }
            return codeFields(of: kind).contains(field)
                ? .code(TeamLibraryVisibleText.visible(text, keepingLineBreaks: true))
                : .text(TeamLibraryVisibleText.visible(text, keepingLineBreaks: false))
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .text(number.boolValue ? String(localized: "Yes") : String(localized: "No"))
            }
            return .text(number.stringValue)
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8)
        else { return .notSet }
        return .code(TeamLibraryVisibleText.visible(json, keepingLineBreaks: false))
    }

    // Known fields in the order the item's editor shows them, then any field a newer build wrote, by name.
    private static func ordered(_ fields: [String], kind: String) -> [String] {
        let known = knownOrder(of: kind)
        return fields.sorted { left, right in
            switch (known.firstIndex(of: left), known.firstIndex(of: right)) {
            case let (left?, right?): return left < right
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return left < right
            }
        }
    }

    private static func knownOrder(of kind: String) -> [String] {
        switch kind {
        case "library_connection":
            [
                "name", "type", "host", "port", "database", "username", "sshConfig", "sshProfileId", "sslConfig",
                "safeModeLevel", "aiPolicy", "connectTimeoutSeconds", "queryTimeoutSeconds", "redisDatabase",
                "additionalFields", "color", "iconName", "localOnly", "startupCommands", "tunnelCommand"
            ]
        case "library_folder":
            ["name", "parent_client_id", "sort_order"]
        case "library_query":
            ["name", "keyword", "query", "folder_client_id", "connection_client_id", "sort_order"]
        default:
            []
        }
    }

    private static func codeFields(of kind: String) -> Set<String> {
        switch kind {
        case "library_connection": ["startupCommands"]
        case "library_query": ["query"]
        default: []
        }
    }

    // A field a newer build wrote keeps its wire name, which is a technical term.
    private static func label(of field: String, kind: String) -> String {
        switch (kind, field) {
        case (_, "name"): String(localized: "Name")
        case ("library_connection", "type"): String(localized: "Type")
        case ("library_connection", "host"): String(localized: "Host")
        case ("library_connection", "port"): String(localized: "Port")
        case ("library_connection", "database"): String(localized: "Database")
        case ("library_connection", "username"): String(localized: "User")
        case ("library_connection", "sshConfig"): String(localized: "SSH")
        case ("library_connection", "sshProfileId"): String(localized: "SSH Profile")
        case ("library_connection", "sslConfig"): String(localized: "SSL/TLS")
        case ("library_connection", "safeModeLevel"): String(localized: "Safe Mode")
        case ("library_connection", "aiPolicy"): String(localized: "AI Policy")
        case ("library_connection", "connectTimeoutSeconds"): String(localized: "Connect Timeout")
        case ("library_connection", "queryTimeoutSeconds"): String(localized: "Query Timeout")
        case ("library_connection", "redisDatabase"): String(localized: "Database Index")
        case ("library_connection", "additionalFields"): String(localized: "Driver Options")
        case ("library_connection", "color"): String(localized: "Color")
        case ("library_connection", "iconName"): String(localized: "Icon")
        case ("library_connection", "localOnly"): String(localized: "Local Only")
        case ("library_connection", "startupCommands"): String(localized: "Startup Commands")
        case ("library_connection", "tunnelCommand"): String(localized: "Tunnel Command")
        case ("library_folder", "parent_client_id"), ("library_query", "folder_client_id"): String(localized: "Folder")
        case ("library_query", "connection_client_id"): String(localized: "Connection")
        case ("library_query", "keyword"): String(localized: "Keyword")
        case ("library_query", "query"): "SQL"
        case (_, "sort_order"): String(localized: "Position")
        default: TeamLibraryVisibleText.name(field)
        }
    }
}
