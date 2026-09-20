import Foundation
import TableProModels
import TableProOracleCore

nonisolated struct ConnectionFormEdits: Equatable, Sendable {
    nonisolated struct SSHTunnel: Equatable, Sendable {
        var host: String
        var port: Int?
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
            Self.differs(field, from: opening, to: self)
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
        if changed(\.sshTunnel) { applySSHTunnel(to: &connection, changedSince: opening?.sshTunnel) }
        if changed(\.oracle) { applyOracleOptions(to: &connection, changedSince: opening?.oracle) }
        return connection
    }

    private static func differs<Root, Value: Equatable>(
        _ field: KeyPath<Root, Value>,
        from opening: Root?,
        to current: Root
    ) -> Bool {
        guard let opening else { return true }
        return opening[keyPath: field] != current[keyPath: field]
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

    private func applySSHTunnel(to connection: inout DatabaseConnection, changedSince opening: SSHTunnel?) {
        guard let sshTunnel else {
            connection.sshEnabled = false
            connection.sshConfiguration = nil
            return
        }
        func changed<Value: Equatable>(_ field: KeyPath<SSHTunnel, Value>) -> Bool {
            Self.differs(field, from: opening, to: sshTunnel)
        }

        var configuration = connection.sshConfiguration ?? SSHConfiguration()
        if changed(\.host) { configuration.host = sshTunnel.host }
        if changed(\.port) { configuration.port = sshTunnel.port }
        if changed(\.username) { configuration.username = sshTunnel.username }
        if changed(\.authMethod) { configuration.authMethod = sshTunnel.authMethod }
        if changed(\.privateKeyPath) { configuration.privateKeyPath = sshTunnel.privateKeyPath }
        if opening == nil {
            connection.sshEnabled = true
            if configuration.macEnabled != nil {
                configuration.macEnabled = true
            }
        }
        connection.sshConfiguration = configuration
    }

    private func applyOracleOptions(to connection: inout DatabaseConnection, changedSince opening: OracleOptions?) {
        guard let oracle else { return }
        func changed<Value: Equatable>(_ field: KeyPath<OracleOptions, Value>) -> Bool {
            Self.differs(field, from: opening, to: oracle)
        }

        typealias Key = OracleConnectionOptions.AdditionalFieldKey
        if changed(\.identifierMode) {
            connection.additionalFields[Key.connectionType] = oracle.identifierMode.rawValue
        }
        if changed(\.serviceName) { connection.additionalFields[Key.serviceName] = oracle.serviceName }
        if changed(\.sid) { connection.additionalFields[Key.sid] = oracle.sid }
        if changed(\.role) { connection.additionalFields[Key.role] = oracle.role.rawValue }
        if changed(\.networkEncryption) {
            connection.additionalFields[Key.networkEncryption] = oracle.networkEncryption.rawValue
        }
    }
}
