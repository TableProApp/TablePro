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
    // The uses each shared row's last check resolved, so a synchronous answer names the same SSH chain.
    private var resolvedUses: [UUID: [SharedRowLocalUse]] = [:]

    internal init(
        approvals: ConnectionApprovalStore = .localCredentials,
        ask: @escaping Ask = LocalCredentialPrompt.ask,
        sshDocument: @escaping SSHDocument = { await SSHConfigCache.shared.current() }
    ) {
        self.approvals = approvals
        self.ask = ask
        self.sshDocument = sshDocument
    }

    // Synchronous, so it names a shared row's SSH chain only as its last check resolved it; before any check, a stored
    // approval of SSH use at this destination stands in, and the connect's own check decides.
    internal func requiresApproval(_ connection: DatabaseConnection) -> Bool {
        guard connection.isSharedRow else { return !isApproved(connection, uses: []) }
        if let uses = resolvedUses[connection.id] {
            return !isApproved(connection, uses: uses)
        }
        let known = connection.sharedRowLocalUses(sshUses: [])
        guard connection.opensSharedSSHTunnel else { return !isApproved(connection, uses: known) }
        return !isApproved(connection, uses: known) || !approvals.hasApproved(connection, itemPrefix: "ssh.")
    }

    internal func confirm(_ connection: DatabaseConnection) async -> Bool {
        (try? await approve(connection, trigger: .request)) != nil
    }

    internal func check(_ connection: DatabaseConnection, trigger: ConnectTrigger) async throws {
        try await approve(connection, trigger: trigger)
    }

    // Asked again when the uses changed while the question was open, such as a profile edit, so what is approved is
    // what the person read.
    private func approve(_ connection: DatabaseConnection, trigger: ConnectTrigger) async throws {
        var uses = await sharedRowUses(of: connection)
        while !isApproved(connection, uses: uses) {
            guard trigger == .request else { throw LocalCredentialConsentError.needsPerson }
            switch await ask(Self.question(for: connection, uses: uses)) {
            case .approved:
                let current = await sharedRowUses(of: connection)
                guard Set(current) == Set(uses) else {
                    uses = current
                    continue
                }
                approvals.approve(connection, extra: Self.items(uses))
            case .declined:
                throw LocalCredentialConsentError.declined
            case .unanswered:
                throw LocalCredentialConsentError.unanswered
            }
        }
    }

    private func sharedRowUses(of connection: DatabaseConnection) async -> [SharedRowLocalUse] {
        guard connection.isSharedRow else { return [] }
        let config = SSHProfileStorage.shared.refreshingLinkedProfile(connection).resolvedSSHConfig
        var ssh: [SharedRowLocalUse] = []
        if connection.opensSharedSSHTunnel {
            let document = await sshDocument()
            ssh = await Task.detached { DatabaseConnection.sshUses(config, document: document) }.value
        }
        let uses = connection.sharedRowLocalUses(sshUses: ssh)
        resolvedUses[connection.id] = uses
        return uses
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
        case .agent(let socket, let server):
            labeled(SSHAuthMethod.sshAgent.displayName, socket.isEmpty ? server : "\(socket), \(server)")
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
    // An empty socket is the one `SSH_AUTH_SOCK` names.
    case agent(socket: String, server: String)
    case key(path: String, server: String)
    case profile(UUID)
    case file(path: String)

    var approvalItem: String {
        switch self {
        case .agent(let socket, let server): "ssh.agent=" + socket + "@" + server
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

    @MainActor
    var opensSharedSSHTunnel: Bool {
        isSharedRow && SSHProfileStorage.shared.refreshingLinkedProfile(self).resolvedSSHConfig.enabled
    }

    // `sshUses` are the tunnel's, which `sshUses(_:document:)` resolves off the main actor.
    @MainActor
    func sharedRowLocalUses(sshUses: [SharedRowLocalUse]) -> [SharedRowLocalUse] {
        guard isSharedRow else { return [] }
        let routed = SSHProfileStorage.shared.refreshingLinkedProfile(self)
        let config = routed.resolvedSSHConfig
        var uses = config.enabled ? sshUses : []
        if config.enabled, case .profile(let id, _) = routed.sshTunnelMode {
            uses.append(.profile(id))
        }
        uses += routed.localFileUses(tunnel: config)
        var seen: Set<SharedRowLocalUse> = []
        return uses.filter { seen.insert($0).inserted }
    }

    private static func server(_ host: String, _ port: Int) -> String {
        "\(host):\(port)"
    }

    // The keys `LibSSH2TunnelFactory.effectiveKeyPaths` offers: the named ones, else ssh's defaults unless the config
    // allows only named identities.
    private static func keyPaths(_ target: ResolvedSSHTarget) -> [String] {
        if !target.identityFiles.isEmpty { return target.identityFiles }
        return target.identitiesOnly ? [] : [""]
    }

    // As `LibSSH2TunnelFactory.buildAuthenticator` and `buildJumpAuthenticator` sign in, to the servers `~/.ssh/config`
    // resolves. It may run `Match exec` or look a name up, so it runs off the main actor. A chain that does not resolve
    // fails at the connect, so it is asked about as the row names it.
    nonisolated static func sshUses(_ config: SSHConfiguration, document: SSHConfigDocument) -> [SharedRowLocalUse] {
        guard let chain = try? LibSSH2TunnelFactory.resolveChainConfiguration(config: config, document: document) else {
            return namedSSHUses(config)
        }
        let primary = server(chain.primary.host, chain.primary.port)
        var uses: [SharedRowLocalUse] = []
        switch config.authMethod {
        case .privateKey:
            uses += keyPaths(chain.primary).map { .key(path: $0, server: primary) }
        case .sshAgent:
            uses.append(.agent(socket: chain.primary.agentSocketPath, server: primary))
        case .password, .keyboardInteractive, .none:
            break
        }
        for jump in chain.jumps {
            let hop = jump.formHop ?? SSHJumpHost()
            let target = jump.target
            let hopServer = server(target.host, target.port)
            switch hop.authMethod {
            case .privateKey:
                uses += keyPaths(target).map { .key(path: $0, server: hopServer) }
            case .sshAgent where target.agentDisabled:
                let paths = hop.privateKeyPath.isEmpty ? keyPaths(target) : [hop.privateKeyPath]
                uses += paths.map { .key(path: $0, server: hopServer) }
            case .sshAgent:
                uses.append(.agent(socket: target.agentSocketPath, server: hopServer))
                if !hop.privateKeyPath.isEmpty {
                    uses.append(.key(path: hop.privateKeyPath, server: hopServer))
                }
            }
        }
        return uses
    }

    nonisolated private static func namedSSHUses(_ config: SSHConfiguration) -> [SharedRowLocalUse] {
        let primary = server(config.host, config.port ?? 22)
        var uses: [SharedRowLocalUse] = []
        switch config.authMethod {
        case .privateKey: uses.append(.key(path: config.privateKeyPath, server: primary))
        case .sshAgent: uses.append(.agent(socket: config.agentSocketPath, server: primary))
        case .password, .keyboardInteractive, .none: break
        }
        for hop in config.jumpHosts {
            let hopServer = server(hop.host, hop.port ?? 22)
            switch hop.authMethod {
            case .privateKey: uses.append(.key(path: hop.privateKeyPath, server: hopServer))
            case .sshAgent: uses.append(.agent(socket: config.agentSocketPath, server: hopServer))
            }
        }
        return uses
    }

    // A database file or socket this Mac would open. MotherDuck's `md:`, a server URL, memory and a file the SSH server
    // holds are not here; a path from the root or the home folder always is.
    @MainActor
    private func localFileUses(tunnel: SSHConfiguration) -> [SharedRowLocalUse] {
        func local(_ value: String?) -> String? {
            guard let path = value?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
            if path.hasPrefix("/") || path.hasPrefix("~") { return path }
            let lowered = path.lowercased()
            let remote = path == ":memory:"
                || ["md:", "libsql://", "http://", "https://", "ws://", "wss://"].contains { lowered.hasPrefix($0) }
            return remote ? nil : path
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
        // A host given as a path is the server's socket, or the folder that holds it; a tunnel never dials one here.
        if !tunnel.enabled, host.hasPrefix("/") {
            paths.append(host)
        }
        if let socket = local(localSocketPath) {
            paths.append(socket)
        }
        return paths.map { .file(path: $0) }
    }
}
