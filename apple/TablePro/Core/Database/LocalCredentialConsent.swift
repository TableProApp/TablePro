//
//  LocalCredentialConsent.swift
//  TablePro
//

import Foundation
import TableProConnectionLibrary
import TableProPluginKit
import TableProSSHConfig

internal struct LocalCredentialQuestion: Equatable, Sendable {
    let connectionName: String
    let uses: [String]
    let destination: String
    let origin: ConnectionOrigin
}

internal enum LocalCredentialConsentError: Error, Equatable, Sendable {
    case declined
    case unanswered
    case needsPerson
}

extension LocalCredentialConsentError: LocalizedError {
    internal var errorDescription: String? {
        switch self {
        case .declined:
            String(localized: "Signing in with credentials from this Mac was not approved.")
        case .unanswered:
            String(localized: "Nobody answered the sign-in prompt in time.")
        case .needsPerson:
            String(localized: "TablePro does not sign in to a new server with credentials from this Mac on its own.")
        }
    }

    internal var recoverySuggestion: String? {
        switch self {
        case .declined:
            nil
        case .unanswered:
            String(localized: "Try again and answer the prompt in TablePro.")
        case .needsPerson:
            String(localized: "Connect again to review the sign-in and approve it.")
        }
    }
}

// A gesture asks through `confirm` before its attempt, and the stored approval lets that connect sign in.
@MainActor
internal final class LocalCredentialConsent {
    internal typealias Ask = @MainActor (LocalCredentialQuestion) async -> ConsentAnswer
    internal typealias SSHDocument = @Sendable () async -> SSHConfigDocument

    internal static let shared = LocalCredentialConsent()

    private let approvals: ConnectionApprovalStore
    private let ask: Ask
    private let sshDocument: SSHDocument
    // `~/.ssh/config` as the last asynchronous check read it, so a synchronous answer names the same hops.
    private var lastDocument: SSHConfigDocument?

    internal init(
        approvals: ConnectionApprovalStore = .localCredentials,
        ask: @escaping Ask = LocalCredentialPrompt.ask,
        sshDocument: @escaping SSHDocument = { await SSHConfigCache.shared.current() }
    ) {
        self.approvals = approvals
        self.ask = ask
        self.sshDocument = sshDocument
    }

    internal func requiresApproval(_ connection: DatabaseConnection) -> Bool {
        !isApproved(connection, uses: connection.sharedRowLocalUses(document: lastDocument))
    }

    internal func confirm(_ connection: DatabaseConnection) async -> Bool {
        let uses = await sharedRowUses(of: connection)
        guard !isApproved(connection, uses: uses) else { return true }
        guard await ask(Self.question(for: connection, uses: uses)) == .approved else { return false }
        approvals.approve(connection, extra: Self.items(uses))
        return true
    }

    internal func check(_ connection: DatabaseConnection, trigger: ConnectTrigger) async throws {
        let uses = await sharedRowUses(of: connection)
        guard !isApproved(connection, uses: uses) else { return }
        guard trigger == .request else { throw LocalCredentialConsentError.needsPerson }
        switch await ask(Self.question(for: connection, uses: uses)) {
        case .approved:
            approvals.approve(connection, extra: Self.items(uses))
        case .declined:
            throw LocalCredentialConsentError.declined
        case .unanswered:
            throw LocalCredentialConsentError.unanswered
        }
    }

    private func sharedRowUses(of connection: DatabaseConnection) async -> [SharedRowLocalUse] {
        guard connection.isSharedRow else { return [] }
        let document = await sshDocument()
        lastDocument = document
        return connection.sharedRowLocalUses(document: document)
    }

    private func isApproved(_ connection: DatabaseConnection, uses: [SharedRowLocalUse]) -> Bool {
        approvals.isApproved(connection, extra: Self.items(uses))
    }

    private static func items(_ uses: [SharedRowLocalUse]) -> Set<String> {
        Set(uses.map(\.approvalItem))
    }

    internal static func question(for connection: DatabaseConnection, uses: [SharedRowLocalUse] = []) -> LocalCredentialQuestion {
        let fields = PluginMetadataRegistry.shared.snapshot(for: connection.type)?
            .connection.additionalConnectionFields ?? []
        return LocalCredentialQuestion(
            connectionName: connection.name,
            uses: ConnectionFieldCatalog.localCredentialUses(in: connection.additionalFields).map { use in
                describe(use, fields: fields)
            } + uses.map(describe),
            destination: SSHProfileStorage.shared.refreshingLinkedProfile(connection).destinationSummary,
            origin: connection.origin
        )
    }

    // In the form's words where the plugin declares the field, so the person reads what they would have picked.
    internal static func describe(_ use: LocalCredentialUse, fields: [ConnectionField]) -> String {
        guard let field = fields.first(where: { $0.id == use.fieldId }) else {
            let name = ConnectionSecretOptions.mongoOption(in: use.fieldId) == nil
                ? use.fieldId
                : String(use.fieldId.dropFirst(ConnectionSecretOptions.mongoOptionPrefix.count))
            return labeled(name, use.value)
        }
        switch field.fieldType {
        case .dropdown(let options):
            return labeled(field.label, options.first { $0.value == use.value }?.label ?? use.value)
        case .toggle where use.value == "true":
            return field.label
        default:
            return labeled(field.label, use.value)
        }
    }

    // Each SSH use names the server it signs in to, so a hop the person never typed is in the question.
    internal static func describe(_ use: SharedRowLocalUse) -> String {
        switch use {
        case .agent(let server):
            labeled(SSHAuthMethod.sshAgent.displayName, server)
        case .key(let path, let server):
            labeled(SSHAuthMethod.privateKey.displayName, path.isEmpty ? server : "\(path), \(server)")
        case .profile(let id):
            labeled(String(localized: "SSH Profile"), SSHProfileStorage.shared.profile(for: id)?.name ?? id.uuidString)
        case .file(let path):
            labeled(String(localized: "Database File"), path)
        }
    }

    private static func labeled(_ label: String, _ value: String) -> String {
        String(format: String(localized: "%@: %@"), label, value)
    }
}

// What a row from another origin (a team's copy, a linked folder's file) would use of this Mac when it connects, as
// this Mac's SSH client (`LibSSH2TunnelFactory`) and `~/.ssh/config` dial it: the agent, a key file (an empty path is
// the keys ssh finds itself), a linked SSH profile, each SSH use with the server it signs in to, and a database file or
// socket here. Another account picked the server, so each use is approved per destination, as a driver's local sign-in
// is. The core lists the same for its own SSH transports (`Core.sharedRowLocalUses`); this list stays the Mac's
// because its SSH client tries other methods and reads `~/.ssh/config` itself.
internal enum SharedRowLocalUse: Hashable, Sendable {
    case agent(server: String)
    case key(path: String, server: String)
    case profile(UUID)
    case file(path: String)

    var approvalItem: String {
        switch self {
        case .agent(let server): "ssh.agent@" + server
        case .key(let path, let server): "ssh.key=" + path + "@" + server
        case .profile(let id): "ssh.profile=" + id.uuidString
        case .file(let path): "file=" + path
        }
    }
}

extension DatabaseConnection {
    var isSharedRow: Bool {
        origin == .teamLibrary || origin == .linkedFolder
    }

    // `document` is `~/.ssh/config` as the tunnel reads it; nil lists only the hops the row names.
    @MainActor
    func sharedRowLocalUses(document: SSHConfigDocument?) -> [SharedRowLocalUse] {
        guard isSharedRow else { return [] }
        let routed = SSHProfileStorage.shared.refreshingLinkedProfile(self)
        let config = routed.resolvedSSHConfig
        var uses: [SharedRowLocalUse] = []
        if config.enabled {
            uses += Self.sshUses(config, document: document)
            if case .profile(let id, _) = routed.sshTunnelMode {
                uses.append(.profile(id))
            }
        }
        uses += routed.localFileUses(tunnel: config)
        var seen: Set<SharedRowLocalUse> = []
        return uses.filter { seen.insert($0).inserted }
    }

    private static func server(_ host: String, _ port: Int?) -> String {
        "\(host):\(port ?? 22)"
    }

    // The keys `LibSSH2TunnelFactory.effectiveKeyPaths` offers: the named ones, else ssh's defaults unless the config
    // allows only named identities.
    private static func keyPaths(_ target: ResolvedSSHTarget?, named: String) -> [String] {
        guard let target else { return [named] }
        if !target.identityFiles.isEmpty { return target.identityFiles }
        return target.identitiesOnly ? [] : [""]
    }

    // As `LibSSH2TunnelFactory.buildAuthenticator` and `buildJumpAuthenticator` sign in.
    private static func sshUses(_ config: SSHConfiguration, document: SSHConfigDocument?) -> [SharedRowLocalUse] {
        let chain = document.flatMap { try? LibSSH2TunnelFactory.resolveChainConfiguration(config: config, document: $0) }
        let primary = server(config.host, config.port)
        var uses: [SharedRowLocalUse] = []
        switch config.authMethod {
        case .privateKey:
            uses += keyPaths(chain?.primary, named: config.privateKeyPath).map { .key(path: $0, server: primary) }
        case .sshAgent:
            uses.append(.agent(server: primary))
        case .password, .keyboardInteractive, .none:
            break
        }
        let hops: [(hop: SSHJumpHost, target: ResolvedSSHTarget?)]
        if let chain {
            hops = chain.jumps.map { (hop: $0.formHop ?? SSHJumpHost(), target: Optional($0.target)) }
        } else {
            hops = config.jumpHosts.map { (hop: $0, target: nil) }
        }
        for (hop, target) in hops {
            let hopServer = target.map { server($0.originalHost, $0.port) } ?? server(hop.host, hop.port)
            switch hop.authMethod {
            case .privateKey:
                uses += keyPaths(target, named: hop.privateKeyPath).map { .key(path: $0, server: hopServer) }
            case .sshAgent where target?.agentDisabled == true:
                let paths = hop.privateKeyPath.isEmpty ? keyPaths(target, named: "") : [hop.privateKeyPath]
                uses += paths.map { .key(path: $0, server: hopServer) }
            case .sshAgent:
                uses.append(.agent(server: hopServer))
                // With no config read, an agent hop may still fall back to the default keys.
                let fallback = hop.privateKeyPath.isEmpty ? (target == nil ? [""] : []) : [hop.privateKeyPath]
                uses += fallback.map { .key(path: $0, server: hopServer) }
            }
        }
        return uses
    }

    // A database file or socket this Mac would open. MotherDuck's `md:`, a URL, memory and a file the SSH server holds
    // are not here.
    @MainActor
    private func localFileUses(tunnel: SSHConfiguration) -> [SharedRowLocalUse] {
        func local(_ value: String?) -> String? {
            guard let path = value?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty,
                  !path.hasPrefix("md:"), !path.contains("://"), path != ":memory:"
            else { return nil }
            return path
        }
        func inLocalMode(_ modeField: String) -> Bool {
            (additionalFields[modeField] ?? "local") == "local"
        }
        var paths: [String] = []
        if PluginManager.shared.connectionMode(for: type) == .fileBased, !tunnel.forwardsRemoteFile,
           let path = local(database) {
            paths.append(path)
        }
        if inLocalMode("duckdbMode"), let path = local(additionalFields["duckdbFilePath"]) {
            paths.append(path)
        }
        if inLocalMode("libsqlMode"), let path = local(additionalFields["libsqlFilePath"]) {
            paths.append(path)
        }
        let attached = (try? AttachedDatabaseList.decode(additionalFields[AttachedDatabaseList.fieldId])) ?? []
        paths += attached.compactMap { local($0.path) }
        if let socket = local(localSocketPath) {
            paths.append(socket)
        }
        return paths.map { .file(path: $0) }
    }
}
