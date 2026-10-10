import Foundation
import TableProModels

nonisolated enum ConnectionDetailFormatter {
    static func detail(for connection: DatabaseConnection) -> String {
        guard connection.type.isLocalFile else { return networkDetail(for: connection) }
        return fileDetail(connection.database)
    }

    private static func fileDetail(_ path: String) -> String {
        guard path != LocalDatabaseLocation.inMemoryPath else { return String(localized: "In Memory") }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    private static func socketDetail(_ path: String, database: String) -> String {
        guard !database.isEmpty else { return String(format: String(localized: "Mac socket %@"), path) }
        return String(format: String(localized: "%1$@ on Mac socket %2$@"), database, path)
    }

    private static func networkDetail(for connection: DatabaseConnection) -> String {
        if let socketPath = connection.macSocketPath {
            return socketDetail(socketPath, database: connection.database)
        }
        var endpoint = connection.host
        let defaultPort = connection.type.defaultPort
        if !defaultPort.isEmpty, String(connection.port) != defaultPort {
            endpoint += ":\(connection.port)"
        }
        if !connection.database.isEmpty {
            endpoint += "/\(connection.database)"
        }
        guard connection.sshEnabled, let ssh = connection.sshConfiguration, !ssh.host.isEmpty else {
            return endpoint
        }
        return String(format: String(localized: "%1$@ via %2$@"), endpoint, ssh.host)
    }
}
