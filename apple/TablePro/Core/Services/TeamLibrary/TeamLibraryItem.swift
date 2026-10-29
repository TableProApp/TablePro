//
//  TeamLibraryItem.swift
//  TablePro
//

import Foundation
import TableProCloudAPI
import TableProImport

internal typealias TeamLibraryChange = Components.Schemas.LibraryChange
internal typealias TeamLibraryEdit = Components.Schemas.LibraryEdit
internal typealias TeamLibraryData = [String: OpenAPIValueContainer]

internal enum TeamLibraryKind {
    static let connection = "connection"
    static let folder = "folder"
    static let query = "query"
}

// /v1 stores uuid-typed client IDs in lowercase and /v2 keeps them as sent, so the app matches them without case.
internal struct TeamLibraryKey: Hashable, Codable, Sendable {
    let kind: String
    let clientID: String

    init(kind: String, clientID: String) {
        self.kind = kind
        self.clientID = clientID.lowercased()
    }

    init(_ change: TeamLibraryChange) {
        self.init(kind: change.kind, clientID: change.clientId)
    }

    init(_ edit: TeamLibraryEdit) {
        self.init(kind: edit.kind.rawValue, clientID: edit.clientId)
    }
}

internal struct TeamLibraryFolderData: Codable, Equatable, Sendable {
    var name: String
    var parentClientID: String?
    var sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case name
        case parentClientID = "parent_client_id"
        case sortOrder = "sort_order"
    }

    init(name: String, parentClientID: String?, sortOrder: Int) {
        self.name = name
        self.parentClientID = parentClientID
        self.sortOrder = sortOrder
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        parentClientID = try container.decodeIfPresent(String.self, forKey: .parentClientID)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    }

    func matches(_ other: TeamLibraryFolderData) -> Bool {
        name == other.name && sortOrder == other.sortOrder && TeamLibraryID.same(parentClientID, other.parentClientID)
    }
}

internal struct TeamLibraryQueryData: Codable, Equatable, Sendable {
    var name: String
    var query: String
    var keyword: String?
    var folderClientID: String?
    var connectionClientID: String?
    var sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case name
        case query
        case keyword
        case folderClientID = "folder_client_id"
        case connectionClientID = "connection_client_id"
        case sortOrder = "sort_order"
    }

    init(
        name: String,
        query: String,
        keyword: String?,
        folderClientID: String?,
        connectionClientID: String?,
        sortOrder: Int
    ) {
        self.name = name
        self.query = query
        self.keyword = keyword
        self.folderClientID = folderClientID
        self.connectionClientID = connectionClientID
        self.sortOrder = sortOrder
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        query = try container.decodeIfPresent(String.self, forKey: .query) ?? ""
        keyword = try container.decodeIfPresent(String.self, forKey: .keyword)
        folderClientID = try container.decodeIfPresent(String.self, forKey: .folderClientID)
        connectionClientID = try container.decodeIfPresent(String.self, forKey: .connectionClientID)
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    }

    func matches(_ other: TeamLibraryQueryData) -> Bool {
        name == other.name && query == other.query && sortOrder == other.sortOrder
            && (keyword ?? "") == (other.keyword ?? "")
            && TeamLibraryID.same(folderClientID, other.folderClientID)
            && TeamLibraryID.same(connectionClientID, other.connectionClientID)
    }
}

internal enum TeamLibraryID {
    static func of(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    static func same(_ lhs: String?, _ rhs: String?) -> Bool {
        let left = lhs.flatMap { $0.isEmpty ? nil : $0.lowercased() }
        let right = rhs.flatMap { $0.isEmpty ? nil : $0.lowercased() }
        return left == right
    }
}

internal enum TeamLibraryPayload {
    // The server refuses a whole push when a key at any depth names a secret (api.md, Team library).
    private static let secretSuffixes = ["password", "passphrase", "token", "privatekey", "secret", "securefields", "passwordsource"]

    static func data(from value: some Encodable) throws -> TeamLibraryData {
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(TeamLibraryData.self, from: encoded)
        return try withoutSecretKeys(decoded)
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from data: TeamLibraryData?) -> Value? {
        guard let data, let encoded = try? JSONEncoder().encode(data) else { return nil }
        return try? JSONDecoder().decode(type, from: encoded)
    }

    static func byteCount(of data: TeamLibraryData) -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return (try? encoder.encode(data).count) ?? .max
    }

    static func isSecretKey(_ key: String) -> Bool {
        let normalized = key.lowercased().filter { !" _-.".contains($0) }
        return secretSuffixes.contains { normalized.hasSuffix($0) }
    }

    private static func withoutSecretKeys(_ data: TeamLibraryData) throws -> TeamLibraryData {
        var kept: TeamLibraryData = [:]
        for (key, value) in data where !isSecretKey(key) {
            kept[key] = try OpenAPIValueContainer(unvalidatedValue: stripped(value.value))
        }
        return kept
    }

    private static func stripped(_ value: (any Sendable)?) -> (any Sendable)? {
        switch value {
        case let object as [String: (any Sendable)?]:
            var kept: [String: (any Sendable)?] = [:]
            for (key, member) in object where !isSecretKey(key) {
                kept[key] = stripped(member)
            }
            return kept
        case let array as [(any Sendable)?]:
            return array.map { stripped($0) }
        default:
            return value
        }
    }
}

extension TeamLibraryChange {
    var key: TeamLibraryKey {
        TeamLibraryKey(self)
    }

    var dataValues: TeamLibraryData? {
        data?.additionalProperties
    }

    var folder: TeamLibraryFolderData? {
        guard kind == TeamLibraryKind.folder, !deleted else { return nil }
        return TeamLibraryPayload.decode(TeamLibraryFolderData.self, from: dataValues)
    }

    var query: TeamLibraryQueryData? {
        guard kind == TeamLibraryKind.query, !deleted else { return nil }
        return TeamLibraryPayload.decode(TeamLibraryQueryData.self, from: dataValues)
    }

    // A pulled connection is authored by another account and lands here with no confirmation step, so anything the app
    // would run by itself is dropped before it is shown.
    var connection: ExportableConnection? {
        guard kind == TeamLibraryKind.connection, !deleted,
              let settings = TeamLibraryPayload.decode(ExportableConnection.self, from: dataValues)
        else { return nil }
        return settings.sanitizedForImport().withoutStartupCommands().withoutTunnelCommand()
    }

    // The folder a query is in or a folder is under.
    var containerClientID: String? {
        folder?.parentClientID ?? query?.folderClientID
    }
}
