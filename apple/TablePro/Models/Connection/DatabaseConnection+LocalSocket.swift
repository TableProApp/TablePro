//
//  DatabaseConnection+LocalSocket.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension DatabaseType {
    var supportsLocalSocket: Bool {
        PluginMetadataRegistry.shared.snapshot(for: self)?.connection.defaultLocalSocketPath != nil
    }

    // libpq names the socket file after the port, so the path is a directory and Port stays.
    var localSocketIsDirectory: Bool {
        supportsLocalSocket && pluginTypeId == DatabaseType.postgresql.pluginTypeId
    }
}

// MySQL dials the path itself, PostgreSQL `<directory>/.s.PGSQL.<port>`, so `path` is that directory.
struct LocalSocketEndpoint: Equatable {
    let path: String
    let port: Int
    let socketFile: String
    let issue: String?

    init(path: String, port: Int, type: DatabaseType) {
        guard type.localSocketIsDirectory else {
            self.path = path
            self.port = port
            socketFile = path
            issue = MySQLLocalSocket.issue(for: path)?.message
            return
        }
        let endpoint = PostgreSQLLocalSocket.endpoint(path: path, port: port)
        self.path = endpoint.directory
        self.port = endpoint.port
        socketFile = endpoint.socketFile
        issue = PostgreSQLLocalSocket.issue(for: endpoint)?.message
    }
}

extension DatabaseConnection {
    var supportsLocalSocket: Bool {
        type.supportsLocalSocket
    }

    // A tunnel connects to its forwarded port, never this Mac's socket.
    var localSocketPath: String? {
        get {
            guard supportsLocalSocket, activeTunnelKind == nil else { return nil }
            return MySQLLocalSocket.path(in: additionalFields)
        }
        set {
            let path = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if path.isEmpty {
                additionalFields.removeValue(forKey: MySQLLocalSocket.fieldKey)
            } else {
                additionalFields[MySQLLocalSocket.fieldKey] = path
            }
        }
    }

    var localSocketEndpoint: LocalSocketEndpoint? {
        localSocketPath.map { LocalSocketEndpoint(path: $0, port: port, type: type) }
    }

    // The file connect(2) opens, which is what tells two local servers apart.
    var localSocketFile: String? {
        localSocketEndpoint?.socketFile
    }

    // libpq never negotiates TLS on a Unix socket, whatever sslmode says.
    var localSocketSkipsTLS: Bool {
        localSocketPath != nil && type.localSocketIsDirectory
    }

    var timeoutEndpointName: String {
        localSocketFile ?? host.nilIfEmpty ?? name
    }
}
