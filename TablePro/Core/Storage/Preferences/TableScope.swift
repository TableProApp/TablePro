//
//  TableScope.swift
//  TablePro
//

import Foundation

struct TableScope: Hashable, Codable, Sendable {
    let connectionId: UUID
    let database: String?
    let schema: String?
    let table: String

    init(connectionId: UUID, database: String?, schema: String?, table: String) {
        self.connectionId = connectionId
        self.database = database
        self.schema = schema
        self.table = table
    }

    var storageComponent: String {
        Self.encode([connectionId.uuidString, database ?? "", schema ?? "", table])
    }

    /// Everything a key for this container starts with, so a container that is renamed can move
    /// every table's saved state without knowing which tables exist. The list is loaded lazily and
    /// a table nobody has opened this session still has settings on disk.
    static func storagePrefix(connectionId: UUID, database: String?, schema: String?) -> String {
        var parts = [connectionId.uuidString, database ?? ""]
        if let schema { parts.append(schema) }
        return encode(parts) + "."
    }

    private static func encode(_ parts: [String]) -> String {
        parts
            .map { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0 }
            .joined(separator: ".")
    }
}
