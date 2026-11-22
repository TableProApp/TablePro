//
//  ConnectionRecordInvariants.swift
//  TablePro
//

import Foundation
import TableProConnectionLibrary
import TableProPluginKit
import TableProSSHConfig

// The rules the old save wrote by overwriting the whole record. The merge keeps another writer's value key by key, and a
// kept value can break a rule that spans keys, so Save, the reviewed definition and Test pass their record through here.
enum ConnectionRecordInvariants {
    enum Use: Equatable {
        case save
        case test
    }

    struct Outcome: Equatable {
        var record: DatabaseConnection
        // Plugin secure values the record held in plain text, by field id. Save moves them where the Keychain has none.
        var plaintextSecrets: [String: String] = [:]
    }

    // `traits` describe the record's own type, `originalTraits` the type the editor loaded.
    static func enforce(
        _ record: DatabaseConnection,
        traits: ConnectionTypeTraits,
        originalTraits: ConnectionTypeTraits?,
        context: EditorContext,
        use: Use = .save
    ) -> Outcome {
        var record = record
        let plaintext = removeSecureValues(from: &record, traits, originalTraits)
        removeFieldsOfTypeLeft(from: &record, traits, originalTraits)
        keepOneOfferedTransport(&record, traits)
        alignSSHLink(&record)
        removeTransportLeftovers(from: &record, traits)
        alignHostAndPortWithHostList(&record, traits)
        alignSignIn(&record, traits, context, use: use)
        return Outcome(record: record, plaintextSecrets: plaintext)
    }

    private static func removeSecureValues(
        from record: inout DatabaseConnection,
        _ traits: ConnectionTypeTraits,
        _ originalTraits: ConnectionTypeTraits?
    ) -> [String: String] {
        var plaintext: [String: String] = [:]
        for fieldId in ConnectionEditorEngine.secretFieldIds(traits, originalTraits: originalTraits) {
            guard let value = record.additionalFields.removeValue(forKey: fieldId), !value.isEmpty else { continue }
            plaintext[fieldId] = value
        }
        return plaintext
    }

    private static func removeFieldsOfTypeLeft(
        from record: inout DatabaseConnection,
        _ traits: ConnectionTypeTraits,
        _ originalTraits: ConnectionTypeTraits?
    ) {
        guard let originalTraits, originalTraits.type != record.type else { return }
        for field in originalTraits.fields where traits.field(field.id) == nil {
            record.additionalFields[field.id] = nil
        }
    }

    // The first switched-on transport is the one the editor loads, and it stays only where this type can dial it.
    private static func keepOneOfferedTransport(_ record: inout DatabaseConnection, _ traits: ConnectionTypeTraits) {
        record.keepOnlyFirstTransport()
        guard let kind = record.switchedOnTransports.first, !offers(kind, record, traits) else { return }
        switch kind {
        case .ssh, .remoteFile, .remoteDatabaseSession:
            record.sshTunnelMode = .disabled
        case .cloudflare:
            record.cloudflareTunnelMode = .disabled
        case .cloudSQLProxy:
            record.cloudSQLProxyMode = .disabled
        case .socksProxy:
            record.socksProxyMode = .disabled
        case .tunnelCommand:
            record.tunnelCommandMode = .disabled
        }
    }

    private static func offers(_ kind: ConnectionTunnelKind, _ record: DatabaseConnection, _ traits: ConnectionTypeTraits) -> Bool {
        let forwards = dialsForwardedEndpoint(record, traits)
        switch kind {
        case .ssh, .remoteFile, .remoteDatabaseSession:
            return traits.supportsRemoteDatabaseFile || (forwards && traits.supportsSSH)
        case .cloudflare: return forwards && traits.supportsCloudflareTunnel
        case .cloudSQLProxy: return forwards && traits.supportsCloudSQLProxy
        case .socksProxy: return forwards && traits.supportsSOCKSProxy
        case .tunnelCommand: return forwards && traits.supportsTunnelCommand
        }
    }

    private static func dialsForwardedEndpoint(_ record: DatabaseConnection, _ traits: ConnectionTypeTraits) -> Bool {
        guard traits.connectionMode != .network else { return true }
        guard let endpointFields = traits.serverEndpointFields,
              let hostField = traits.field(endpointFields.hostFieldId)
        else { return false }
        return traits.fields.isVisible(hostField, forValues: record.additionalFields)
    }

    // The tunnel mode is what a connect reads; the legacy profile id and configuration follow it.
    private static func alignSSHLink(_ record: inout DatabaseConnection) {
        switch record.sshTunnelMode {
        case .disabled:
            record.sshProfileId = nil
            record.sshConfig.enabled = false
        case .inline(let config):
            record.sshProfileId = nil
            record.sshConfig = config
        case .profile(let id, let snapshot):
            record.sshProfileId = id
            record.sshConfig = snapshot
        }
    }

    private static func removeTransportLeftovers(from record: inout DatabaseConnection, _ traits: ConnectionTypeTraits) {
        let forwardsPort = record.sshTunnelMode != .disabled && !traits.supportsRemoteDatabaseFile && traits.socketForwardApplies
        if !forwardsPort {
            record.additionalFields[DatabaseConnection.sshForwardUnixSocketPathKey] = nil
        }
        // A connect through a transport drops the socket, and the editor loads such a record as the transport.
        if !traits.supportsLocalSocket || !record.switchedOnTransports.isEmpty {
            record.additionalFields[MySQLLocalSocket.fieldKey] = nil
        }
        if !traits.supportsRemoteDatabaseFile {
            record.clearRemoteFilePath()
        }
    }

    private static func alignHostAndPortWithHostList(_ record: inout DatabaseConnection, _ traits: ConnectionTypeTraits) {
        guard let hostList = traits.fields.endpointHostList, let raw = record.additionalFields[hostList.id] else { return }
        let primary = HostListEndpoint.parseList(raw, defaultPort: traits.defaultPort).first
            ?? HostListEndpoint(host: traits.defaultHost ?? "localhost", port: traits.defaultPort)
        record.host = primary.host
        record.port = primary.port
    }

    private static func alignSignIn(
        _ record: inout DatabaseConnection,
        _ traits: ConnectionTypeTraits,
        _ context: EditorContext,
        use: Use
    ) {
        if let profile = context.credentialProfile(record.credentialMode.profileId) {
            record.username = profile.username
        }
        let showsPassword = !traits.hidesBuiltInPassword
            && !traits.fields.hidesPassword(forValues: record.additionalFields)
            && traits.connectionMode != .fileBased
        if !showsPassword {
            record.additionalFields["promptForPassword"] = nil
        }
        // A prompt arrives as an override and a linked profile resolves first, so the source would never run.
        if use == .test, record.credentialMode.profileId != nil || record.promptForPassword {
            record.passwordSource = nil
        }
    }
}

private extension DatabaseConnection {
    mutating func clearRemoteFilePath() {
        sshConfig.remoteFilePath = ""
        switch sshTunnelMode {
        case .disabled:
            break
        case .inline(var config):
            config.remoteFilePath = ""
            sshTunnelMode = .inline(config)
        case .profile(let id, var snapshot):
            snapshot.remoteFilePath = ""
            sshTunnelMode = .profile(id: id, snapshot: snapshot)
        }
    }
}
