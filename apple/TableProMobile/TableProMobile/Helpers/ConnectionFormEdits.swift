import Foundation
import TableProModels
import TableProOracleCore

nonisolated struct ConnectionFormEdits: Equatable, Sendable {
    nonisolated struct JumpHostEdit: Equatable, Sendable, Identifiable {
        var id: UUID
        var host: String
        var port: Int?
        var username: String
    }

    nonisolated struct SSHTunnel: Equatable, Sendable {
        var host: String
        var port: Int?
        var username: String
        var authMethod: SSHConfiguration.SSHAuthMethod
        var privateKeyPath: String?
        var jumpHosts: [JumpHostEdit] = []
    }

    nonisolated struct OracleOptions: Equatable, Sendable {
        var identifierMode: OracleConnectionOptions.IdentifierMode
        var serviceName: String
        var sid: String
        var role: OracleConnectionOptions.Role
        var networkEncryption: OracleConnectionOptions.NetworkEncryption
    }

    nonisolated struct IAMOptions: Equatable, Sendable {
        var method: IAMSignIn?
        var region: String
        var accessKeyId: String
        var profileName: String
        var rdsEndpoint: String
        var replicationGroupId: String
    }

    var name: String
    var type: DatabaseType
    var host: String
    var port: Int
    var username: String
    var database: String
    var groupId: UUID?
    var tagId: UUID?
    var iconName: String?
    var safeModeLevel: SafeModeLevel
    var sslMode: SSLConfiguration.SSLMode?
    var sshTunnel: SSHTunnel?
    var oracle: OracleOptions?
    var iam: IAMOptions?

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
        if changed(\.iconName) { connection.iconName = iconName }
        if changed(\.safeModeLevel) {
            connection.safeModeLevel = safeModeLevel
            connection.isReadOnly = safeModeLevel.blocksWrites
        }
        if changed(\.sslMode) { applySSLMode(to: &connection) }
        if changed(\.sshTunnel) { applySSHTunnel(to: &connection, changedSince: opening?.sshTunnel) }
        if changed(\.oracle) { applyOracleOptions(to: &connection, changedSince: opening?.oracle) }
        if changed(\.iam) { applyIAMOptions(to: &connection, changedSince: opening?.iam) }
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
        if changed(\.jumpHosts) {
            configuration.jumpHosts = Self.rebuiltJumpHosts(
                sshTunnel.jumpHosts,
                over: configuration.jumpHosts,
                changedSince: opening?.jumpHosts
            )
        }
        // The Mac reads a missing `enabled` as off.
        if opening == nil {
            connection.sshEnabled = true
            configuration.macEnabled = true
        } else if configuration.macEnabled == nil, connection.sshEnabled {
            configuration.macEnabled = true
        }
        connection.sshConfiguration = configuration
    }

    // Each hop keeps the record's Mac credential fields and takes only the fields the form changed.
    // Where the form left the chain alone, the record's chain wins, since another device may have
    // saved it while the form was open: a field edit keeps the record's order, a hop removed there
    // stays removed, and a hop added there keeps its place after the hop before it.
    private static func rebuiltJumpHosts(
        _ edits: [JumpHostEdit],
        over current: [SSHJumpHost],
        changedSince opening: [JumpHostEdit]?
    ) -> [SSHJumpHost] {
        let currentHops = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let openingHops = Dictionary((opening ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let editedHops = Dictionary(edits.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        func applyingEdit(to hop: SSHJumpHost) -> SSHJumpHost {
            guard let edit = editedHops[hop.id] else { return hop }
            var hop = hop
            let opened = openingHops[hop.id]
            if differs(\JumpHostEdit.host, from: opened, to: edit) { hop.host = edit.host }
            if differs(\JumpHostEdit.port, from: opened, to: edit) { hop.port = edit.port }
            if differs(\JumpHostEdit.username, from: opened, to: edit) { hop.username = edit.username }
            return hop
        }

        if let opening, edits.map(\.id) == opening.map(\.id) {
            return current.map(applyingEdit(to:))
        }

        var merged = edits.compactMap { edit -> SSHJumpHost? in
            if let hop = currentHops[edit.id] { return applyingEdit(to: hop) }
            guard openingHops[edit.id] == nil else { return nil }
            return SSHJumpHost(id: edit.id, host: edit.host, port: edit.port, username: edit.username)
        }
        guard opening != nil else { return merged }
        for (index, hop) in current.enumerated() where openingHops[hop.id] == nil && editedHops[hop.id] == nil {
            let anchor = current[..<index].reversed().lazy
                .compactMap { previous in merged.firstIndex { $0.id == previous.id } }
                .first
            merged.insert(hop, at: anchor.map { $0 + 1 } ?? 0)
        }
        return merged
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

    private func applyIAMOptions(to connection: inout DatabaseConnection, changedSince opening: IAMOptions?) {
        guard let iam else { return }
        func changed<Value: Equatable>(_ field: KeyPath<IAMOptions, Value>) -> Bool {
            Self.differs(field, from: opening, to: iam)
        }
        func write(_ value: String, to key: String) {
            connection.additionalFields[key] = value.isEmpty ? nil : value
        }

        typealias Field = IAMSignIn.Field
        if changed(\.method) {
            if let method = iam.method {
                connection.additionalFields[Field.method] = method.pickerValue
            } else if connection.additionalFields[Field.method] != nil {
                connection.additionalFields[Field.method] = IAMSignIn.passwordPickerValue
            }
        }
        if changed(\.region) { write(iam.region, to: Field.region) }
        if changed(\.accessKeyId) { write(iam.accessKeyId, to: Field.accessKeyId) }
        if changed(\.profileName) { write(iam.profileName, to: Field.profileName) }
        if changed(\.rdsEndpoint) { write(iam.rdsEndpoint, to: Field.rdsEndpoint) }
        if changed(\.replicationGroupId) { write(iam.replicationGroupId, to: Field.replicationGroupId) }
    }
}
