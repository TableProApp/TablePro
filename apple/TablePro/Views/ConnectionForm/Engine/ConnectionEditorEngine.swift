//
//  ConnectionEditorEngine.swift
//  TablePro
//

import Foundation
import TableProConnectionLibrary
import TableProPluginKit
import TableProSSHConfig

// Facts from outside the draft that change what the editor shows, passed in by the store.
struct EditorContext: Equatable, Sendable {
    var isNew = true
    var originalType: DatabaseType?
    var savedName = ""
    var aiEnabled = false
    var syncEnabled = false
    var participatesInSync = false
    var managedSafeModeMinimum: SafeModeLevel?
    var credentialProfiles: [CredentialProfile] = []
    var credentialProfilesLoadFailed = false
    var sshProfiles: [SSHProfile] = []
    var sshProfilesLoadFailed = false
    var sshConfigEntries: [SSHConfigEntry] = []

    func credentialProfile(_ id: UUID?) -> CredentialProfile? {
        guard let id else { return nil }
        return credentialProfiles.first { $0.id == id }
    }

    func sshProfile(_ id: UUID?) -> SSHProfile? {
        guard let id else { return nil }
        return sshProfiles.first { $0.id == id }
    }
}

enum ConnectionEditorEngine {
    static let portRange = 1...65_535

    // MARK: - Values

    // Trimmed whole number in range; empty means the type's default.
    static func parsePort(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isASCII), let value = Int(trimmed), portRange.contains(value) else {
            return nil
        }
        return value
    }

    static func portIssue(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, parsePort(trimmed) == nil else { return nil }
        return portRangeMessage
    }

    // Fix-it wording short enough for the label column, so an issue stays on one line under its label.
    static var portRangeMessage: String {
        String(localized: "Enter a port from 1 to 65535.")
    }

    static func resolvedPort(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits) -> Int {
        parsePort(draft.portText) ?? traits.defaultPort
    }

    static func resolvedHost(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits) -> String {
        draft.host.trimmingCharacters(in: .whitespaces).isEmpty ? (traits.defaultHost ?? "localhost") : draft.host
    }

    static func usesLocalSocket(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits) -> Bool {
        traits.supportsLocalSocket && draft.endpoint == .localSocket
    }

    static func localSocketSkipsTLS(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits) -> Bool {
        usesLocalSocket(draft, traits) && traits.localSocketIsDirectory
    }

    // The driver hands the path to connect(2) unchanged, so `~` is expanded here.
    static func resolvedLocalSocketPath(_ draft: ConnectionDraft) -> String? {
        let trimmed = draft.localSocketPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (trimmed as NSString).expandingTildeInPath
    }

    struct SocketEndpoint: Equatable, Sendable {
        let path: String
        let port: Int
        let socketFile: String
        let issue: String?
    }

    static func localSocketEndpoint(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits) -> SocketEndpoint? {
        guard usesLocalSocket(draft, traits), let path = resolvedLocalSocketPath(draft) else { return nil }
        let port = resolvedPort(draft, traits)
        guard traits.localSocketIsDirectory else {
            return SocketEndpoint(path: path, port: port, socketFile: path, issue: MySQLLocalSocket.issue(for: path)?.message)
        }
        let endpoint = PostgreSQLLocalSocket.endpoint(path: path, port: port)
        return SocketEndpoint(
            path: endpoint.directory,
            port: endpoint.port,
            socketFile: endpoint.socketFile,
            issue: PostgreSQLLocalSocket.issue(for: endpoint)?.message
        )
    }

    static func forwardsToUnixSocket(_ draft: ConnectionDraft) -> Bool {
        draft.transport == .ssh && !draft.sshForwardUnixSocketPath.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Plugin fields

    static func value(of field: ConnectionField, in draft: ConnectionDraft) -> String {
        draft.fieldValues[field.id] ?? field.defaultValue ?? ""
    }

    static func isVisible(_ field: ConnectionField, _ draft: ConnectionDraft, _ traits: ConnectionTypeTraits) -> Bool {
        traits.fields.isVisible(field, forValues: draft.fieldValues)
    }

    static func hidesPassword(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits) -> Bool {
        traits.hidesBuiltInPassword || traits.fields.hidesPassword(forValues: draft.fieldValues)
    }

    static func hidesUsername(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits) -> Bool {
        traits.fields.hidesUsername(forValues: draft.fieldValues)
    }

    static func effectivePromptForPassword(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits) -> Bool {
        draft.credentials.promptsForPassword && !hidesPassword(draft, traits) && traits.connectionMode != .fileBased
    }

    static func clearsStoredPassword(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits) -> Bool {
        !draft.credentials.usesProfile
            && !effectivePromptForPassword(draft, traits)
            && draft.credentials.password.isEmpty
            && draft.credentials.storedPasswordState == .stored
    }

    static func passwordSourceInUse(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits) -> PasswordSource? {
        draft.credentials.usesProfile || effectivePromptForPassword(draft, traits) ? nil : draft.credentials.passwordSource
    }

    static func visibleHostListFields(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits) -> [ConnectionField] {
        traits.fields.filter { field in
            guard field.section == .connection, case .hostList = field.fieldType else { return false }
            return isVisible(field, draft, traits)
        }
    }

    static func dialsForwardedEndpoint(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits) -> Bool {
        guard traits.connectionMode != .network else { return true }
        guard let endpointFields = traits.serverEndpointFields,
              let hostField = traits.field(endpointFields.hostFieldId)
        else { return false }
        return isVisible(hostField, draft, traits)
    }

    // MARK: - Transports

    // `.ssh` and `.remoteFile` share one SSH server, so only one of them is ever offered.
    static func availableTransports(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits) -> [ConnectionTunnelKind?] {
        guard !usesLocalSocket(draft, traits) else { return [nil] }
        var transports: [ConnectionTunnelKind?] = [nil]
        let forwards = dialsForwardedEndpoint(draft, traits)
        if traits.supportsRemoteDatabaseFile {
            transports.append(.remoteFile)
        } else if forwards, traits.supportsSSH {
            transports.append(.ssh)
        }
        guard forwards else { return transports }
        if traits.supportsCloudflareTunnel { transports.append(.cloudflare) }
        if traits.supportsCloudSQLProxy { transports.append(.cloudSQLProxy) }
        if traits.supportsSOCKSProxy { transports.append(.socksProxy) }
        if traits.supportsTunnelCommand { transports.append(.tunnelCommand) }
        return transports
    }

    static func normalized(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits) -> ConnectionDraft {
        guard !availableTransports(draft, traits).contains(draft.transport) else { return draft }
        var normalized = draft
        normalized.selectTransport(nil)
        return normalized
    }

    // MARK: - SSL

    static func showsSSL(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits) -> Bool {
        traits.supportsSSL && !localSocketSkipsTLS(draft, traits)
    }

    // Through a TCP forward the driver checks the certificate against the host behind it, which some drivers cannot do.
    static func dialsTunnelTCPForward(_ draft: ConnectionDraft) -> Bool {
        switch draft.transport {
        case .ssh: return !forwardsToUnixSocket(draft)
        case .cloudflare, .socksProxy, .tunnelCommand: return true
        case .cloudSQLProxy, .remoteFile, .remoteDatabaseSession, nil: return false
        }
    }

    static func offeredSSLModes(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits) -> [SSLMode] {
        let supported = traits.ssl.supportedModes
        guard dialsTunnelTCPForward(draft) else { return supported }
        return supported.filter { traits.ssl.modesThroughTunnel.contains($0) }
    }

    // MARK: - Safe Mode

    static func safeModeFloor(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits, _ context: EditorContext) -> SafeModeFloor? {
        SafeModeFloor.resolve(
            isEngineReadOnly: traits.isEngineReadOnly,
            opensRemoteDatabaseFile: draft.transport == .remoteFile && draft.ssh.remoteFileAccess == .readOnlyCopy,
            managedMinimum: context.managedSafeModeMinimum
        )
    }

    static func effectiveSafeModeLevel(
        _ draft: ConnectionDraft,
        _ traits: ConnectionTypeTraits,
        _ context: EditorContext
    ) -> SafeModeLevel {
        safeModeFloor(draft, traits, context)?.raising(draft.safety.safeModeLevel) ?? draft.safety.safeModeLevel
    }

    static func effectiveManualCommit(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits) -> Bool {
        traits.manualCommitAvailable && draft.safety.commitMode == .manual
    }

    // MARK: - SSH resolution

    enum SSHResolution: Equatable {
        case disabled
        case inline(SSHConfiguration)
        case profile(SSHProfile)
        // The record names a profile this Mac does not have: it stays linked, with the stored snapshot.
        case unresolvedProfile(id: UUID, snapshot: SSHConfiguration)
    }

    static func sshResolution(_ draft: ConnectionDraft, _ context: EditorContext) -> SSHResolution {
        guard draft.usesSSHServer else { return .disabled }
        guard let profileId = draft.ssh.profileId else {
            return .inline(draft.ssh.inlineConfiguration(enabled: true))
        }
        if let profile = context.sshProfile(profileId) {
            return .profile(profile)
        }
        var snapshot = draft.ssh.profileSnapshot ?? draft.ssh.inlineConfiguration(enabled: true)
        snapshot.enabled = true
        return .unresolvedProfile(id: profileId, snapshot: snapshot)
    }

    static func sshProfileIsUnresolved(_ draft: ConnectionDraft, _ context: EditorContext) -> Bool {
        if case .unresolvedProfile = sshResolution(draft, context) { return true }
        return false
    }

    static func credentialProfileIsMissing(_ draft: ConnectionDraft, _ context: EditorContext) -> Bool {
        guard let id = draft.credentials.mode.profileId else { return false }
        return context.credentialProfile(id) == nil
    }

    // MARK: - Host list

    // Host and Port seed an empty list. A Host equal to the type's own default was filled in while hidden and stays out.
    static func endpointList(
        _ raw: String,
        host: String,
        port: Int,
        traits: ConnectionTypeTraits
    ) -> String? {
        let effectivePort = port > 0 ? port : traits.defaultPort
        let defaultHost = traits.defaultHost ?? "localhost"
        let hasRows = raw.split(separator: ",").contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard hasRows else {
            return HostListEndpoint.parse(host.isEmpty ? defaultHost : host, defaultPort: effectivePort)?.entry
        }
        let listed = HostListEndpoint.parseList(raw, defaultPort: traits.defaultPort)
        guard host != defaultHost || effectivePort != traits.defaultPort,
              let primary = HostListEndpoint.parse(host, defaultPort: effectivePort),
              !listed.contains(primary)
        else { return raw }
        return raw + "," + primary.entry
    }
}
