import Foundation
import TableProModels

nonisolated enum ConnectionDetailFormatter {
    static func detail(for connection: DatabaseConnection) -> String {
        switch connection.type {
        case .sqlite, .duckdb:
            return fileDetail(connection.database)
        default:
            return networkDetail(for: connection)
        }
    }

    private static func fileDetail(_ path: String) -> String {
        guard path != LocalDatabaseLocation.inMemoryPath else { return String(localized: "In Memory") }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    private static func networkDetail(for connection: DatabaseConnection) -> String {
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
