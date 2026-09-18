import Foundation
import TableProModels
import TableProOracleCore

nonisolated struct ConnectionFormEdits: Equatable, Sendable {
    nonisolated struct SSHTunnel: Equatable, Sendable {
        var host: String
        var port: Int
        var username: String
        var authMethod: SSHConfiguration.SSHAuthMethod
        var privateKeyPath: String?
    }

    nonisolated struct OracleOptions: Equatable, Sendable {
        var identifierMode: OracleConnectionOptions.IdentifierMode
        var serviceName: String
        var sid: String
        var role: OracleConnectionOptions.Role
        var networkEncryption: OracleConnectionOptions.NetworkEncryption
    }

    var name: String
    var type: DatabaseType
    var host: String
    var port: Int
    var username: String
    var database: String
    var groupId: UUID?
    var tagId: UUID?
    var safeModeLevel: SafeModeLevel
    var sslMode: SSLConfiguration.SSLMode?
    var sshTunnel: SSHTunnel?
    var oracle: OracleOptions?

    static func tagIds(selecting tagId: UUID?, over existing: [UUID]) -> [UUID] {
        let others = existing.dropFirst().filter { $0 != tagId }
        guard let tagId else { return Array(others) }
        return [tagId] + others
    }

    func applied(to base: DatabaseConnection, changedSince opening: ConnectionFormEdits?) -> DatabaseConnection {
        func changed<Value: Equatable>(_ field: KeyPath<ConnectionFormEdits, Value>) -> Bool {
            guard let opening else { return true }
            return opening[keyPath: field] != self[keyPath: field]
        }

        var connection = base
        if changed(\.name) { connection.name = name }
        if changed(\.type) { connection.type = type }
        if changed(\.host) { connection.host = host }
        if changed(\.port) { connection.port = port }
        if changed(\.username) { connection.username = username }
        if changed(\.database) { connection.database = database }
        if changed(\.groupId) { connection.groupId = groupId }
        if changed(\.tagId) { connection.tagIds = Self.tagIds(selecting: tagId, over: connection.tagIds) }
        if changed(\.safeModeLevel) {
            connection.safeModeLevel = safeModeLevel
            connection.isReadOnly = safeModeLevel.blocksWrites
        }
        if changed(\.sslMode) { applySSLMode(to: &connection) }
        if changed(\.sshTunnel) { applySSHTunnel(to: &connection) }
        if changed(\.oracle) { applyOracleOptions(to: &connection) }
        return connection
    }

    private func applySSLMode(to connection: inout DatabaseConnection) {
        guard let sslMode else {
            connection.sslEnabled = false
            return
        }
        var configuration = connection.sslConfiguration ?? SSLConfiguration()
        configuration.mode = sslMode
        connection.sslConfiguration = configuration
        connection.sslEnabled = sslMode != .disable
    }

    private func applySSHTunnel(to connection: inout DatabaseConnection) {
        guard let sshTunnel else {
            connection.sshEnabled = false
            connection.sshConfiguration = nil
            return
        }
        var configuration = connection.sshConfiguration ?? SSHConfiguration()
        configuration.host = sshTunnel.host
        configuration.port = sshTunnel.port
        configuration.username = sshTunnel.username
        configuration.authMethod = sshTunnel.authMethod
        configuration.privateKeyPath = sshTunnel.privateKeyPath
        if configuration.macEnabled != nil {
            configuration.macEnabled = true
        }
        connection.sshEnabled = true
        connection.sshConfiguration = configuration
    }

    private func applyOracleOptions(to connection: inout DatabaseConnection) {
        guard let oracle else { return }
        typealias Key = OracleConnectionOptions.AdditionalFieldKey
        connection.additionalFields[Key.connectionType] = oracle.identifierMode.rawValue
        connection.additionalFields[Key.serviceName] = oracle.serviceName
        connection.additionalFields[Key.sid] = oracle.sid
        connection.additionalFields[Key.role] = oracle.role.rawValue
        connection.additionalFields[Key.networkEncryption] = oracle.networkEncryption.rawValue
    }
}
