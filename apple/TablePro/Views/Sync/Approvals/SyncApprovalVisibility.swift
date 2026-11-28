//
//  SyncApprovalVisibility.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProRedisCore
import TableProSSHConfig

// The settings of a connection that decide which of its rows the connection form shows: this Mac's copy, with each
// value the pull brings laid over it. Nil is a setting neither side says, which hides nothing.
internal struct SyncApprovalConnectionState: Equatable {
    var type: String?
    var sshEnabled: Bool?
    var sshAuthMethod: String?
    var sshProfileId: String?
    var sslMode: String?
    var additionalFields: [String: String] = [:]

    @MainActor
    init(_ connection: DatabaseConnection) {
        type = connection.type.rawValue
        sshEnabled = connection.sshConfig.enabled
        sshAuthMethod = connection.sshConfig.authMethod.rawValue
        sshProfileId = connection.sshProfileId?.uuidString
        sslMode = connection.sslConfig.mode.rawValue
        additionalFields = connection.additionalFields
    }

    init(
        type: String? = nil,
        sshEnabled: Bool? = nil,
        sshAuthMethod: String? = nil,
        sshProfileId: String? = nil,
        sslMode: String? = nil,
        additionalFields: [String: String] = [:]
    ) {
        self.type = type
        self.sshEnabled = sshEnabled
        self.sshAuthMethod = sshAuthMethod
        self.sshProfileId = sshProfileId
        self.sslMode = sslMode
        self.additionalFields = additionalFields
    }

    // `path` is a member in the personal kinds' snake case, `value` its pulled JSON, already parsed.
    mutating func apply(_ path: [String], _ value: Any?) {
        let text = value as? String
        switch path {
        case ["type"]:
            type = text
        case ["ssh_config", "enabled"]:
            sshEnabled = (value as? NSNumber)?.boolValue ?? false
        case ["ssh_config", "auth_method"]:
            sshAuthMethod = text
        case ["ssh_profile_id"]:
            sshProfileId = text
        case ["ssl_config", "mode"]:
            sslMode = text
        default:
            guard path.count == 2, path[0] == "additional_fields" else { return }
            additionalFields[path[1]] = SyncApprovalVisibility.entryValue(value)
        }
    }
}

// Which pulled values a person sees, by the rules the connection form lays its rows out with (ConnectionEditorEngine,
// Layout). A value hidden here still goes with the record's decision, so a row hides only when the form's rule settles
// it: with no traits the driver is not one this Mac knows, and a setting the Mac cannot read keeps what it controls in
// sight. `sshProfileResolves` says this Mac holds the SSH profile the record links, whose server then stands in for the
// connection's own.
internal enum SyncApprovalVisibility {
    static func shows(
        _ path: [String],
        state: SyncApprovalConnectionState,
        traits: ConnectionTypeTraits?,
        sshProfileResolves: Bool = false
    ) -> Bool {
        guard let head = path.first, let traits else { return true }
        let sub = path.count > 1 ? path[1] : nil
        let network = traits.connectionMode == .network
        switch head {
        case "host", "port":
            return network
        case "database":
            if traits.connectionMode == .fileBased {
                return traits.localFilePathField == .database
            }
            return traits.showsBuiltInDatabaseField
        case "username":
            return network && !traits.fields.hidesUsername(forValues: state.additionalFields)
        // Which credentials a connection sends, whatever its driver: a profile's secure fields reach file and API
        // drivers too.
        case "credential_profile_id", "credential_reference":
            return true
        case "redis_database":
            return traits.field(RedisDatabaseIndex.fieldName) != nil
        case "ssh_config":
            return sshShows(sub, state: state, traits: traits, sshProfileResolves: sshProfileResolves)
        case "ssh_profile_id", "ssh_route":
            return sshApplies(traits) && state.sshEnabled != false
        case "ssl_config":
            return sslShows(sub, state: state, traits: traits)
        // The core keeps these for the apps that connect through it; the Mac's form has no row for them.
        case "auth_mode", "network_options":
            return false
        case "additional_fields":
            guard let id = sub, let field = traits.field(id) else { return true }
            return !controllersKnown(field, traits: traits, values: state.additionalFields)
                || traits.fields.isVisible(field, forValues: state.additionalFields)
        default:
            return true
        }
    }

    // A driver that opens its file over SSH (Remote File) uses the same SSH server rows as a tunnel.
    private static func sshApplies(_ traits: ConnectionTypeTraits) -> Bool {
        traits.supportsSSH || traits.supportsRemoteDatabaseFile
    }

    // A dropdown that controls a field, at a value none of its options names, is a setting this Mac cannot read: the
    // driver may still use the field, so it shows.
    private static func controllersKnown(
        _ field: ConnectionField,
        traits: ConnectionTypeTraits,
        values: [String: String],
        visited: Set<String> = []
    ) -> Bool {
        guard let rule = field.visibleWhen, !visited.contains(field.id) else { return true }
        guard let controller = traits.field(rule.fieldId) else { return false }
        if case .dropdown(let options) = controller.fieldType {
            let value = values[rule.fieldId] ?? controller.defaultValue ?? ""
            guard options.contains(where: { $0.value == value }) else { return false }
        }
        return controllersKnown(controller, traits: traits, values: values, visited: visited.union([field.id]))
    }

    private static func sshShows(
        _ sub: String?,
        state: SyncApprovalConnectionState,
        traits: ConnectionTypeTraits,
        sshProfileResolves: Bool
    ) -> Bool {
        guard sshApplies(traits) else { return false }
        if sub == "enabled" {
            return true
        }
        guard state.sshEnabled != false else { return false }
        // A profile this Mac holds carries the server and its sign-in, so the connection's own are unused. One it does
        // not hold leaves them in use.
        let ownServer = state.sshProfileId == nil || !sshProfileResolves
        let method = authMethod(state.sshAuthMethod)
        switch sub {
        case "host", "port", "username", "auth_method":
            return ownServer
        // The key file, and under the agent the identity it offers first.
        case "private_key_path":
            return ownServer && (method == nil || method == .privateKey || method == .sshAgent)
        case "agent_socket_path":
            return ownServer && (method == nil || method == .sshAgent)
        case "remote_file_path":
            return traits.supportsRemoteDatabaseFile
        case "remote_file_access":
            return traits.supportsRemoteDatabaseFile && traits.supportsRemoteDatabaseSession
        default:
            return true
        }
    }

    private static func sslShows(_ sub: String?, state: SyncApprovalConnectionState, traits: ConnectionTypeTraits) -> Bool {
        guard traits.supportsSSL else { return false }
        let mode = state.sslMode.flatMap(SSLMode.init(rawValue:))
        switch sub {
        case "mode":
            return true
        case "ca_certificate_path":
            return traits.ssl.supportsPerConnectionCertificatePaths && (mode == nil || mode == .verifyCa || mode == .verifyIdentity)
        case "client_certificate_path", "client_key_path":
            return traits.ssl.supportsPerConnectionCertificatePaths && mode != .disabled
        // Only the core reads a TLS server name; the Mac's form has none.
        case "server_name":
            return false
        default:
            return true
        }
    }

    // Each spelling a build has written, the display name and the older camel case; nil for one the Mac cannot read.
    private static func authMethod(_ wire: String?) -> SSHAuthMethod? {
        guard let wire else { return nil }
        let key = wire.lowercased().filter { $0.isLetter }
        return SSHAuthMethod.allCases.first { $0.rawValue.lowercased().filter { $0.isLetter } == key }
    }

    // A driver field arrives as its `{"id", "value"}` entry; an older shape may send the bare value.
    static func entryValue(_ value: Any?) -> String? {
        if let entry = value as? [String: Any] {
            return entry["value"] as? String
        }
        return value as? String
    }
}
