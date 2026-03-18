//
//  DeeplinkHandler.swift
//  TablePro
//

import Foundation
import os

enum DeeplinkAction {
    case connect(connectionName: String)
    case openTable(connectionName: String, tableName: String, databaseName: String?)
    case openQuery(connectionName: String, sql: String)
    case importConnection(name: String, host: String, port: Int, type: DatabaseType,
                          username: String, database: String)
}

@MainActor
enum DeeplinkHandler {
    private static let logger = Logger(subsystem: "com.TablePro", category: "DeeplinkHandler")

    static func parse(_ url: URL) -> DeeplinkAction? {
        guard url.scheme == "tablepro" else { return nil }

        let host = url.host(percentEncoded: false)
        switch host {
        case "connect":
            return parseConnect(url)
        case "import":
            return parseImport(url)
        default:
            logger.warning("Unknown deep link host: \(host ?? "nil", privacy: .public)")
            return nil
        }
    }

    // MARK: - Connect parsing

    private static func parseConnect(_ url: URL) -> DeeplinkAction? {
        let components = url.pathComponents.filter { $0 != "/" }
        guard let connectionName = components.first?.removingPercentEncoding,
              !connectionName.isEmpty else { return nil }

        // /connect/{name}/query?sql=...
        if components.count >= 2, components[1] == "query" {
            let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            guard let sql = queryItems?.first(where: { $0.name == "sql" })?.value,
                  !sql.isEmpty else { return nil }
            return .openQuery(connectionName: connectionName, sql: sql)
        }

        // /connect/{name}/database/{db}/table/{table}
        if components.count == 5,
           components[1] == "database",
           components[3] == "table",
           let dbName = components[2].removingPercentEncoding,
           let tableName = components[4].removingPercentEncoding {
            return .openTable(connectionName: connectionName, tableName: tableName,
                              databaseName: dbName)
        }

        // /connect/{name}/table/{table}
        if components.count >= 3, components[1] == "table",
           let tableName = components[2].removingPercentEncoding {
            return .openTable(connectionName: connectionName, tableName: tableName,
                              databaseName: nil)
        }

        // /connect/{name}
        if components.count == 1 {
            return .connect(connectionName: connectionName)
        }

        logger.warning("Unrecognized connect deep link path: \(url.path, privacy: .public)")
        return nil
    }

    // MARK: - Import parsing

    private static func parseImport(_ url: URL) -> DeeplinkAction? {
        guard let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }

        func value(_ key: String) -> String? {
            queryItems.first(where: { $0.name == key })?.value
        }

        guard let name = value("name"), !name.isEmpty,
              let host = value("host"), !host.isEmpty,
              let typeStr = value("type"),
              let dbType = DatabaseType(validating: typeStr)
                ?? PluginMetadataRegistry.shared.allRegisteredTypeIds()
                    .first(where: { $0.lowercased() == typeStr.lowercased() })
                    .map({ DatabaseType(rawValue: $0) })
        else {
            logger.warning("Import deep link missing required params")
            return nil
        }

        let port = value("port").flatMap(Int.init) ?? dbType.defaultPort
        let username = value("username") ?? ""
        let database = value("database") ?? ""

        return .importConnection(name: name, host: host, port: port, type: dbType,
                                 username: username, database: database)
    }

    // MARK: - Resolution

    static func resolveConnection(named name: String) -> DatabaseConnection? {
        let connections = ConnectionStorage.shared.loadConnections()
        return connections.first {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }
}
