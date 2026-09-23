//
//  QuickSwitcherFrecencyKey.swift
//  TablePro
//

import CryptoKit
import Foundation

internal enum QuickSwitcherFrecencyKey {
    internal struct DatabaseQualifier: Hashable, Sendable {
        let database: String?

        init(database: String?, connectionSwitchesDatabases: Bool) {
            guard connectionSwitchesDatabases, let database, !database.isEmpty else {
                self.database = nil
                return
            }
            self.database = database
        }
    }

    static func table(name: String, schema: String?, in qualifier: DatabaseQualifier) -> String {
        qualified("table_\(IdentityPath.qualified(name: name, schema: schema))", by: qualifier)
    }

    static func schema(_ name: String, in qualifier: DatabaseQualifier) -> String {
        qualified("schema_\(name)", by: qualifier)
    }

    static func routine(_ routineId: String, in qualifier: DatabaseQualifier) -> String {
        qualified("routine_\(routineId)", by: qualifier)
    }

    static func trigger(_ triggerId: String, in qualifier: DatabaseQualifier) -> String {
        qualified("trigger_\(triggerId)", by: qualifier)
    }

    static func userType(_ typeId: String, in qualifier: DatabaseQualifier) -> String {
        qualified("usertype_\(typeId)", by: qualifier)
    }

    static func database(_ name: String) -> String {
        "db_\(name)"
    }

    static func savedQuery(_ favoriteId: UUID) -> String {
        "favorite_\(favoriteId.uuidString)"
    }

    static func queryHistory(_ query: String) -> String {
        let digest = SHA256.hash(data: Data(normalizedQuery(query).utf8))
        return "history_" + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func normalizedQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func qualified(_ key: String, by qualifier: DatabaseQualifier) -> String {
        guard let database = qualifier.database else { return key }
        return "@\(IdentityPath.escaped(database, separator: "/"))/\(key)"
    }
}
