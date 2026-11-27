import CryptoKit
import Foundation
import TableProFFI
import TableProImport
import TableProModels

// Who last changed an item, and when, as the server names them to this account.
nonisolated struct TeamLibraryChange: Equatable, Sendable {
    let writer: String?
    let date: Date?

    init(_ item: TeamLibraryItemInfo) {
        let name = item.updatedBy?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        writer = name.isEmpty ? nil : TeamLibraryVisibleText.name(name)
        date = item.updatedAtMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) }
    }

    var isKnown: Bool {
        writer != nil || date != nil
    }
}

nonisolated struct TeamLibraryConnectionItem: Equatable, Identifiable, Sendable {
    // The lowercase id, so a connection keeps its row whatever case the team stores it in.
    let id: String
    let settings: ExportableConnection
    let change: TeamLibraryChange

    var ref: TeamLibraryItemRef {
        TeamLibraryItemRef(kind: .connection, id: id)
    }
}

nonisolated struct TeamLibraryQueryItem: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let query: String
    let keyword: String?
    let folderName: String?
    let change: TeamLibraryChange

    var ref: TeamLibraryItemRef {
        TeamLibraryItemRef(kind: .query, id: id)
    }
}

// A folder's and a query's fields as the team stores them (core ADR 0051, The library moves in).
nonisolated struct TeamLibraryFolderFields: Decodable, Equatable, Sendable {
    var name: String
    var parentClientID: String?

    enum CodingKeys: String, CodingKey {
        case name
        case parentClientID = "parent_client_id"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        parentClientID = try container.decodeIfPresent(String.self, forKey: .parentClientID)
    }
}

nonisolated struct TeamLibraryQueryFields: Decodable, Equatable, Sendable {
    var name: String
    var query: String
    var keyword: String?
    var folderClientID: String?
    var sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case name
        case query
        case keyword
        case folderClientID = "folder_client_id"
        case sortOrder = "sort_order"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        query = try container.decodeIfPresent(String.self, forKey: .query) ?? ""
        keyword = try container.decodeIfPresent(String.self, forKey: .keyword)
        folderClientID = try container.decodeIfPresent(String.self, forKey: .folderClientID)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    }
}

// One team as the Team Library screen shows it.
nonisolated struct TeamLibraryTeam: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let role: TeamRoleTag?
    let canWrite: Bool
    let connections: [TeamLibraryConnectionItem]
    let queries: [TeamLibraryQueryItem]

    // Owners and admins confirm members and rotate at any time (core ADR 0056, Teams).
    var managesKeys: Bool {
        role == .owner || role == .admin
    }

    var isEmpty: Bool {
        connections.isEmpty && queries.isEmpty
    }

    init(_ info: TeamLibraryTeamInfo) {
        id = info.teamId
        name = info.name.flatMap { $0.isEmpty ? nil : TeamLibraryVisibleText.name($0) }
            ?? String(localized: "Team Library")
        role = info.role
        canWrite = info.canWrite
        let folders = Dictionary(
            info.items.compactMap { item -> (String, TeamLibraryFolderFields)? in
                guard item.kind == .folder, let folder = Self.decode(TeamLibraryFolderFields.self, item) else { return nil }
                return (item.id.lowercased(), folder)
            },
            uniquingKeysWith: { first, _ in first }
        )
        var connections: [String: TeamLibraryConnectionItem] = [:]
        var queries: [String: (item: TeamLibraryQueryItem, order: Int)] = [:]
        for item in info.items {
            let id = item.id.lowercased()
            switch item.kind {
            case .connection:
                guard let settings = Self.connection(item) else { continue }
                connections[id] = TeamLibraryConnectionItem(id: id, settings: settings, change: TeamLibraryChange(item))
            case .query:
                guard let fields = Self.decode(TeamLibraryQueryFields.self, item) else { continue }
                let folder = fields.folderClientID.flatMap { folders[$0.lowercased()] }
                queries[id] = (
                    TeamLibraryQueryItem(
                        id: id,
                        name: TeamLibraryVisibleText.name(fields.name),
                        query: fields.query,
                        keyword: fields.keyword,
                        folderName: folder.map { TeamLibraryVisibleText.name($0.name) },
                        change: TeamLibraryChange(item)
                    ),
                    fields.sortOrder
                )
            case .folder:
                continue
            }
        }
        self.connections = connections.values
            .sorted { ($0.settings.name.localizedLowercase, $0.id) < ($1.settings.name.localizedLowercase, $1.id) }
        self.queries = queries.values
            .sorted { lhs, rhs in
                let left = (lhs.item.folderName ?? "", lhs.order, lhs.item.name.localizedLowercase, lhs.item.id)
                let right = (rhs.item.folderName ?? "", rhs.order, rhs.item.name.localizedLowercase, rhs.item.id)
                return left < right
            }
            .map(\.item)
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, _ item: TeamLibraryItemInfo) -> Value? {
        try? JSONDecoder().decode(type, from: Data(item.fieldsJson.utf8))
    }

    // Another account wrote it, and it lands here with no confirmation step, so anything the app would run by itself is
    // dropped before it is shown, and so is a connection whose SSH host ssh would refuse, as on the Mac.
    private static func connection(_ item: TeamLibraryItemInfo) -> ExportableConnection? {
        guard let settings = decode(ExportableConnection.self, item), settings.refusedSSHDestination == nil else {
            return nil
        }
        var sanitized = settings.sanitizedForImport(keepingLocalCredentials: true)
            .withoutStartupCommands()
            .withoutTunnelCommand()
        sanitized.name = TeamLibraryVisibleText.name(sanitized.name)
        return sanitized
    }
}

nonisolated enum TeamLibraryID {
    static func of(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    // The library copy a team connection is added as, the same for one team item every time, so adding it again opens
    // the copy already there instead of making another.
    static func copy(team: String, item: String) -> UUID {
        let digest = SHA256.hash(data: Data("team-library-copy\n\(team)\n\(item.lowercased())".utf8))
        var bytes = Array(digest.prefix(16))
        // RFC 9562 version 8 and the variant bits, so the id reads as a UUID anywhere.
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

// What other members wrote, as text that shows every character it holds. A directional control reorders what a value
// shows (CVE-2021-42574, "Trojan Source"), and a line break or control in a name can push buttons off the screen.
nonisolated enum TeamLibraryVisibleText {
    static let nameLimit = 80

    static func visible(_ text: String, keepingLineBreaks: Bool) -> String {
        var shown = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if keepingLineBreaks, scalar == "\n" || scalar == "\r" || scalar == "\t" {
                shown.append(scalar)
            } else if isHidden(scalar) {
                shown.append(contentsOf: "<U+\(String(format: "%04X", scalar.value))>".unicodeScalars)
            } else {
                shown.append(scalar)
            }
        }
        return String(shown)
    }

    // One line, cut at `nameLimit` characters.
    static func name(_ text: String) -> String {
        let shown = visible(text, keepingLineBreaks: false)
        guard shown.count > nameLimit else { return shown }
        return String(shown.prefix(nameLimit)) + "…"
    }

    private static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x061C, 0x200E, 0x200F, 0x202A ... 0x202E, 0x2066 ... 0x2069, 0x2028, 0x2029:
            true
        default:
            scalar.properties.generalCategory == .control
        }
    }
}
