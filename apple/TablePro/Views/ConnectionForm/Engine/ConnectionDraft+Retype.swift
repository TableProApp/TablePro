//
//  ConnectionDraft+Retype.swift
//  TablePro
//

import Foundation
import TableProConnectionLibrary
import TableProPluginKit

struct RetypeProposal: Equatable, Sendable {
    let from: DatabaseType
    let to: DatabaseType
    // User-facing names of the values the new type cannot hold, for the confirmation.
    let dropped: [String]
    let result: ConnectionDraft

    var needsConfirmation: Bool { !dropped.isEmpty }
}

extension ConnectionDraft {
    // One keep-list decides: whatever the new type supports stays, the rest comes from the new type's defaults.
    func retyped(to newTraits: ConnectionTypeTraits, from oldTraits: ConnectionTypeTraits) -> RetypeProposal {
        var next = ConnectionDraft.new(type: newTraits.type, traits: newTraits)
        next.name = name
        next.environment = environment
        next.appearance = appearance
        next.safety = safety
        next.ai = ai
        next.options = options
        next.ssh = ssh
        next.cloudflare = cloudflare
        next.cloudSQLProxy = cloudSQLProxy
        next.socksProxy = socksProxy
        next.tunnelCommand = tunnelCommand

        let keepsNetworkValues = oldTraits.connectionMode == .network && newTraits.connectionMode == .network
        keepEndpoint(into: &next, keepsNetworkValues: keepsNetworkValues, newTraits: newTraits, oldTraits: oldTraits)
        keepCredentials(into: &next, newTraits: newTraits)
        next.fieldValues.merge(carriedFieldValues(newTraits: newTraits, oldTraits: oldTraits)) { _, carried in carried }
        if let hostList = newTraits.fields.endpointHostList, oldTraits.field(hostList.id) == nil {
            next.fieldValues[hostList.id] = HostListEndpoint.parse(
                ConnectionEditorEngine.resolvedHost(next, newTraits),
                defaultPort: ConnectionEditorEngine.resolvedPort(next, newTraits)
            )?.entry
        }
        keepTransport(into: &next, newTraits: newTraits)
        keepSSL(into: &next, newTraits: newTraits)

        return RetypeProposal(
            from: type,
            to: newTraits.type,
            dropped: droppedValues(next: next, oldTraits: oldTraits),
            result: next
        )
    }

    mutating func retype(to newTraits: ConnectionTypeTraits, from oldTraits: ConnectionTypeTraits) {
        self = retyped(to: newTraits, from: oldTraits).result
    }

    private func keepEndpoint(
        into next: inout ConnectionDraft,
        keepsNetworkValues: Bool,
        newTraits: ConnectionTypeTraits,
        oldTraits: ConnectionTypeTraits
    ) {
        guard keepsNetworkValues else { return }
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        if !trimmedHost.isEmpty, trimmedHost != (oldTraits.defaultHost ?? "") {
            next.host = host
        }
        if let port = ConnectionEditorEngine.parsePort(portText), port != oldTraits.defaultPort {
            next.portText = String(port)
        }
        if oldTraits.showsBuiltInDatabaseField, newTraits.showsBuiltInDatabaseField {
            next.database = database
        }
        if endpoint == .localSocket, newTraits.supportsLocalSocket {
            next.endpoint = .localSocket
            next.localSocketPath = localSocketPath
        }
    }

    private func keepCredentials(into next: inout ConnectionDraft, newTraits: ConnectionTypeTraits) {
        next.credentials.passwordSource = credentials.passwordSource
        next.credentials.storedPasswordState = credentials.storedPasswordState
        guard newTraits.connectionMode != .fileBased else { return }
        next.credentials.mode = credentials.mode
        if newTraits.connectionMode == .network {
            next.credentials.username = credentials.username
        }
        if !newTraits.hidesBuiltInPassword {
            next.credentials.password = credentials.password
            next.credentials.promptsForPassword = credentials.promptsForPassword
        }
    }

    // A field both types declare keeps a value the user set, when the new field can hold it.
    private func carriedFieldValues(newTraits: ConnectionTypeTraits, oldTraits: ConnectionTypeTraits) -> [String: String] {
        var carried: [String: String] = [:]
        for field in newTraits.fields {
            guard let oldField = oldTraits.field(field.id), let value = fieldValues[field.id] else { continue }
            if !field.isSecure, value == (oldField.defaultValue ?? "") { continue }
            if field.isSecure, value.isEmpty { continue }
            if case .dropdown(let options) = field.fieldType, !options.contains(where: { $0.value == value }) { continue }
            carried[field.id] = value
        }
        return carried
    }

    // Not the nearest kind: a kept MySQL port forward would otherwise become SQLite's file copy.
    private func keepTransport(into next: inout ConnectionDraft, newTraits: ConnectionTypeTraits) {
        // A path only Remote File reads would otherwise ride into the saved SSH configuration.
        next.ssh.remoteFilePath = ""
        guard let transport, ConnectionEditorEngine.availableTransports(next, newTraits).contains(transport) else { return }
        next.transport = transport
        if transport == .ssh, newTraits.socketForwardApplies {
            next.sshForwardUnixSocketPath = sshForwardUnixSocketPath
        }
        if transport == .remoteFile {
            next.ssh.remoteFilePath = ssh.remoteFilePath
        }
    }

    private func keepSSL(into next: inout ConnectionDraft, newTraits: ConnectionTypeTraits) {
        guard newTraits.supportsSSL else { return }
        if ssl.origin == .chosen, ConnectionEditorEngine.offeredSSLModes(next, newTraits).contains(ssl.mode) {
            next.selectSSLMode(ssl.mode)
        } else {
            next.reconcileSSLWithPort(traits: newTraits)
        }
        guard newTraits.ssl.supportsPerConnectionCertificatePaths else { return }
        next.ssl.caCertPath = ssl.caCertPath
        next.ssl.clientCertPath = ssl.clientCertPath
        next.ssl.clientKeyPath = ssl.clientKeyPath
        next.ssl.clientKeyPassphrase = ssl.clientKeyPassphrase
    }

    private func droppedValues(next: ConnectionDraft, oldTraits: ConnectionTypeTraits) -> [String] {
        var dropped: [String] = []
        func note(_ label: String, when lost: Bool) {
            if lost, !dropped.contains(label) { dropped.append(label) }
        }
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        note(String(localized: "Host"), when: !trimmedHost.isEmpty && trimmedHost != (oldTraits.defaultHost ?? "")
            && next.host != host)
        let customPort = ConnectionEditorEngine.parsePort(portText).map { $0 != oldTraits.defaultPort } ?? false
        note(String(localized: "Port"), when: customPort && next.portText != portText)
        note(String(localized: "Database"), when: !database.isEmpty && next.database != database)
        note(String(localized: "Socket"), when: endpoint == .localSocket && next.endpoint != .localSocket)
        note(String(localized: "Username"), when: !credentials.username.isEmpty && next.credentials.username != credentials.username)
        note(String(localized: "Password"), when: !credentials.password.isEmpty && next.credentials.password != credentials.password)
        note(
            String(localized: "Ask for the password every time"),
            when: credentials.promptsForPassword && !next.credentials.promptsForPassword
        )
        note(String(localized: "Credential Profile"), when: credentials.usesProfile && !next.credentials.usesProfile)
        if let transport, next.transport != transport {
            note(transport.displayName, when: true)
        }
        let sslLost = (ssl.origin == .chosen && next.ssl.mode != ssl.mode)
            || (!ssl.caCertPath.isEmpty && next.ssl.caCertPath.isEmpty)
            || (!ssl.clientCertPath.isEmpty && next.ssl.clientCertPath.isEmpty)
            || (!ssl.clientKeyPath.isEmpty && next.ssl.clientKeyPath.isEmpty)
        note(String(localized: "SSL/TLS settings"), when: sslLost)
        for field in oldTraits.fields {
            let value = fieldValues[field.id] ?? ""
            let isSet = field.isSecure ? !value.isEmpty : (!value.isEmpty && value != (field.defaultValue ?? ""))
            note(field.label, when: isSet && next.fieldValues[field.id] != value)
        }
        return dropped
    }
}
