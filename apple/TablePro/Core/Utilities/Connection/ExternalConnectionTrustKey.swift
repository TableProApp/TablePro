//
//  ExternalConnectionTrustKey.swift
//  TablePro
//

import Foundation
import TableProUtilities

internal struct ExternalConnectionTrustKey: Hashable, Codable, Sendable {
    internal let databaseType: String
    internal let host: String
    internal let database: String
    internal let username: String
    internal let scopeName: String
    // Optional so entries saved before sockets still decode. Trust covers this exact path only.
    internal let socketPath: String?
    // The saved connection a link opened, nil for one built from the link alone, so trust never crosses between them.
    internal let savedConnectionId: UUID?

    internal init(
        databaseType: String,
        host: String,
        database: String,
        username: String,
        scopeName: String,
        socketPath: String? = nil,
        savedConnectionId: UUID? = nil
    ) {
        let socket = socketPath?.trimmingCharacters(in: .whitespaces)
        self.socketPath = socket?.isEmpty == false ? socket : nil
        self.savedConnectionId = savedConnectionId
        self.databaseType = databaseType.lowercased()
        self.host = self.socketPath == nil ? host.trimmingCharacters(in: .whitespaces).lowercased() : "localhost"
        self.database = database
        self.username = username
        self.scopeName = scopeName.trimmingCharacters(in: .whitespaces)
    }

    internal init(connection: DatabaseConnection, scopeName: String?, isSaved: Bool = false) {
        self.init(
            databaseType: connection.type.rawValue,
            host: connection.host,
            database: connection.database,
            username: connection.username,
            scopeName: scopeName ?? "",
            socketPath: connection.localSocketFile,
            savedConnectionId: isSaved ? connection.id : nil
        )
    }

    internal var isLoopbackHost: Bool {
        LoopbackHost.isLoopback(host)
    }

    internal var displayDescription: String {
        var target = host
        if !username.isEmpty {
            target = "\(username)@\(host)"
        }
        if !database.isEmpty {
            target += "/\(database)"
        }
        if let socketPath {
            target = String(
                format: String(localized: "%1$@ on %2$@"),
                target,
                (socketPath as NSString).abbreviatingWithTildeInPath
            )
        }
        guard !scopeName.isEmpty else { return "\(databaseType) \(target)" }
        return "\(databaseType) \(target) (\(scopeName))"
    }
}
