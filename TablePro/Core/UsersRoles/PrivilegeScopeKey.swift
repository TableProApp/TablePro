import Foundation
import TableProPluginKit

extension PluginPrivilegeScope {
    enum Level: Int, Comparable {
        case server
        case database
        case schema
        case table
        case column

        static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    var level: Level {
        switch self {
        case .server: .server
        case .database: .database
        case .schema: .schema
        case .table: .table
        case .column: .column
        @unknown default: .server
        }
    }

    var persistentKey: String {
        switch self {
        case .server:
            "server"
        case let .database(name):
            "db:\(name)"
        case let .schema(database, schema):
            "db:\(database)/schema:\(schema)"
        case let .table(database, schema, table):
            schema.map { "db:\(database)/schema:\($0)/table:\(table)" }
                ?? "db:\(database)/table:\(table)"
        case let .column(database, schema, table, column):
            schema.map { "db:\(database)/schema:\($0)/table:\(table)/column:\(column)" }
                ?? "db:\(database)/table:\(table)/column:\(column)"
        @unknown default:
            "server"
        }
    }

    var displayPath: String {
        switch self {
        case .server:
            String(localized: "Server")
        case let .database(name):
            name
        case let .schema(database, schema):
            "\(database) › \(schema)"
        case let .table(database, schema, table):
            schema.map { "\(database) › \($0) › \(table)" } ?? "\(database) › \(table)"
        case let .column(database, schema, table, column):
            schema.map { "\(database) › \($0) › \(table) › \(column)" }
                ?? "\(database) › \(table) › \(column)"
        @unknown default:
            String(localized: "Server")
        }
    }

    var displayName: String {
        switch self {
        case .server:
            String(localized: "Server")
        case let .database(name):
            name
        case let .schema(_, schema):
            schema
        case let .table(_, _, table):
            table
        case let .column(_, _, _, column):
            column
        @unknown default:
            String(localized: "Server")
        }
    }

    var symbolName: String {
        switch self {
        case .server: "server.rack"
        case .database: "cylinder"
        case .schema: "folder"
        case .table: "tablecells"
        case .column: "rectangle.split.3x1"
        @unknown default: "server.rack"
        }
    }
}
