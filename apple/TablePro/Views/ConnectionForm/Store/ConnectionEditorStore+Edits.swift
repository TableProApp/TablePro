//
//  ConnectionEditorStore+Edits.swift
//  TablePro
//

import Foundation
import SwiftUI
import TableProPluginKit
import TableProSSHConfig
import TableProSSHTransport

extension ConnectionEditorStore {
    // MARK: - Type

    func proposeRetype(to type: DatabaseType) -> RetypeProposal {
        let newTraits = ConnectionTypeTraits.live(for: type, pluginManager: services.pluginManager)
        return draft.retyped(to: newTraits, from: traits)
    }

    // The chooser's callback: applies at once when nothing is lost, else asks through `pendingRetype`.
    func requestRetype(to type: DatabaseType) {
        isChoosingType = false
        guard type != draft.type else { return }
        let proposal = proposeRetype(to: type)
        if proposal.needsConfirmation {
            pendingRetype = proposal
        } else {
            retype(to: type)
        }
    }

    func confirmPendingRetype() {
        guard let proposal = pendingRetype else { return }
        pendingRetype = nil
        if let pending = pendingPastedURL {
            pendingPastedURL = nil
            applyPasted(pending.parsed, snapshot: pending.snapshot, retypeTo: proposal.to)
            return
        }
        retype(to: proposal.to)
    }

    func cancelPendingRetype() {
        pendingRetype = nil
        pendingPastedURL = nil
    }

    // A running test is for the old type: it is cancelled, and its receipt cleans up what it wrote.
    func retype(to type: DatabaseType) {
        guard type != draft.type else { return }
        cancelTest()
        let newTraits = ConnectionTypeTraits.live(for: type, pluginManager: services.pluginManager)
        let next = draft.retyped(to: newTraits, from: traits).result
        traits = newTraits
        commit(next)
    }

    // MARK: - Coupled edits

    func setPort(_ text: String) {
        update { $0.setPort(text, traits: traits) }
    }

    func selectSSLMode(_ mode: SSLMode) {
        update { $0.selectSSLMode(mode) }
    }

    func selectTransport(_ transport: ConnectionTunnelKind?) {
        update { $0.selectTransport(transport) }
    }

    func selectEndpoint(_ endpoint: ConnectionDraft.Endpoint) {
        update { $0.selectEndpoint(endpoint) }
    }

    func setPasswordPrompt(_ prompts: Bool) {
        update { $0.setPasswordPrompt(prompts, traits: traits) }
    }

    func setCredentialMode(_ mode: CredentialMode) {
        update { $0.setCredentialMode(mode) }
    }

    func switchToInlineCredentials() {
        setCredentialMode(.inline)
    }

    func setEnvironment(_ environment: ConnectionEnvironment) {
        update { $0.setEnvironment(environment) }
    }

    func setSafeModeLevel(_ level: SafeModeLevel) {
        let floor = safeModeFloor
        update { $0.setSafeModeLevel(level, floor: floor) }
    }

    func setManualCommit(_ enabled: Bool) {
        update { $0.setManualCommit(enabled, traits: traits) }
    }

    func setFieldValue(_ value: String, for fieldID: String) {
        update { $0.setFieldValue(value, for: fieldID) }
    }

    func forgetAlwaysAllowed(_ tool: String) {
        update { $0.forgetAlwaysAllowed(tool) }
    }

    @discardableResult
    func addMaskingRule() -> UUID {
        var id = UUID()
        update { id = $0.addMaskingRule() }
        return id
    }

    func removeMaskingRule(id: UUID) {
        update { $0.removeMaskingRule(id: id) }
    }

    func updateMaskingRule(_ rule: MaskingRule) {
        update { $0.updateMaskingRule(rule) }
    }

    func selectSSHProfile(_ id: UUID?) {
        let profiles = context.sshProfiles
        update { $0.selectSSHProfile(id, profiles: profiles) }
    }

    func switchSSHProfileToInline() {
        selectSSHProfile(nil)
    }

    func selectSSHConfigHost(_ host: String) {
        update { $0.selectSSHConfigHost(host) }
    }

    @discardableResult
    func addJumpHost() -> UUID {
        var id = UUID()
        update { id = $0.addJumpHost() }
        return id
    }

    func removeJumpHost(id: UUID) {
        update { $0.removeJumpHost(id: id) }
    }

    func updateJumpHost(_ jumpHost: SSHJumpHost) {
        update { $0.updateJumpHost(jumpHost) }
    }

    func moveJumpHosts(fromOffsets source: IndexSet, toOffset destination: Int) {
        update { $0.moveJumpHosts(fromOffsets: source, toOffset: destination) }
    }

    // MARK: - Profiles

    var selectedCredentialProfile: CredentialProfile? {
        context.credentialProfile(draft.credentials.mode.profileId)
    }

    var credentialProfileIsMissing: Bool {
        ConnectionEditorEngine.credentialProfileIsMissing(draft, context) && !context.credentialProfilesLoadFailed
    }

    var hasPromotableCredentials: Bool {
        !draft.credentials.username.trimmingCharacters(in: .whitespaces).isEmpty
            || !draft.credentials.password.isEmpty
            || ConnectionEditorEngine.effectivePromptForPassword(draft, traits)
            || draft.credentials.passwordSource != nil
    }

    // Promoting what is filled in beats retyping it; a source survives only from a file TablePro last wrote.
    func credentialProfileFromCurrentCredentials() -> CredentialProfile {
        let mode: CredentialPasswordMode
        if ConnectionEditorEngine.effectivePromptForPassword(draft, traits) {
            mode = .prompt
        } else if let source = draft.credentials.passwordSource {
            mode = storage.storeIsTrusted ? .source(source) : .prompt
        } else if ConnectionEditorEngine.usesPgpass(draft, traits) {
            mode = .pgpass
        } else {
            mode = .stored
        }
        return CredentialProfile(
            name: "",
            username: draft.credentials.username.trimmingCharacters(in: .whitespaces),
            passwordMode: mode
        )
    }

    func didSaveCredentialProfile(_ profile: CredentialProfile) {
        isSavingCredentialsAsProfile = false
        refreshContext()
        setCredentialMode(.profile(id: profile.id))
    }

    var selectedSSHProfile: SSHProfile? {
        context.sshProfile(draft.ssh.profileId)
    }

    var sshProfileIsUnresolved: Bool {
        ConnectionEditorEngine.sshProfileIsUnresolved(draft, context)
    }

    var canSaveSSHAsProfile: Bool {
        draft.ssh.profileId == nil && draft.usesSSHServer && !draft.ssh.host.isEmpty
    }

    func sshProfileFromInline() -> SSHProfile {
        let ssh = draft.ssh
        return SSHProfile(
            name: "",
            host: ssh.host,
            port: ConnectionEditorEngine.parsePort(ssh.port),
            username: ssh.username,
            authMethod: ssh.authMethod,
            privateKeyPath: ssh.privateKeyPath,
            agentSocketPath: ssh.resolvedAgentSocketPath,
            jumpHosts: ssh.jumpHosts,
            totpMode: ssh.totpMode,
            totpAlgorithm: ssh.totpAlgorithm,
            totpDigits: ssh.totpDigits,
            totpPeriod: ssh.totpPeriod
        )
    }

    func presentSSHProfileCreation() {
        sshProfileSheet = .create
    }

    func presentSSHProfileEditing() {
        guard let profile = selectedSSHProfile else { return }
        sshProfileSheet = .edit(profile)
    }

    func presentSaveSSHAsProfile() {
        guard canSaveSSHAsProfile else { return }
        sshProfileSheet = .saveCurrent(sshProfileFromInline())
    }

    // A profile saved from the inline values is linked at once; a create or an edit only refreshes the list.
    func didSaveSSHProfile(_ profile: SSHProfile) {
        let linksSaved: Bool
        if case .saveCurrent = sshProfileSheet { linksSaved = true } else { linksSaved = false }
        sshProfileSheet = nil
        refreshContext()
        if linksSaved {
            selectSSHProfile(profile.id)
        }
    }

    func didDeleteSSHProfile() {
        sshProfileSheet = nil
        refreshContext()
    }

    // MARK: - Derived values for rows

    var availableTransports: [ConnectionTunnelKind?] {
        ConnectionEditorEngine.availableTransports(draft, traits)
    }

    var offeredSSLModes: [SSLMode] {
        ConnectionEditorEngine.offeredSSLModes(draft, traits)
    }

    var safeModeFloor: SafeModeFloor? {
        ConnectionEditorEngine.safeModeFloor(draft, traits, context)
    }

    var effectiveSafeModeLevel: SafeModeLevel {
        ConnectionEditorEngine.effectiveSafeModeLevel(draft, traits, context)
    }

    var allowedSafeModeLevels: [SafeModeLevel] {
        SafeModeFloor.levels(allowedBy: safeModeFloor)
    }

    var effectiveManualCommit: Bool {
        ConnectionEditorEngine.effectiveManualCommit(draft, traits)
    }

    var usesLocalSocket: Bool {
        ConnectionEditorEngine.usesLocalSocket(draft, traits)
    }

    var localSocketEndpoint: ConnectionEditorEngine.SocketEndpoint? {
        ConnectionEditorEngine.localSocketEndpoint(draft, traits)
    }

    // Advisory only: the server may start after the connection is saved.
    var localSocketFileStatus: SocketFileStatus? {
        guard let endpoint = localSocketEndpoint, endpoint.issue == nil else { return nil }
        return SocketFileStatus.of(path: endpoint.socketFile)
    }

    // Advisory only: the SSH server is the authority on whether the path resolves.
    var sshForwardSocketPathAdvice: SSHForwardSocketAdvice? {
        SSHForwardSocketAdvice.of(path: draft.sshForwardUnixSocketPath)
    }

    var hostAndPortAreUnused: Bool {
        isDisabled(.builtIn(.port))
    }

    func isDisabled(_ row: EditorRow) -> Bool {
        layout.disabledRows.contains(row)
    }

    var portTLSNotice: PortTLSNotice? {
        guard ConnectionEditorEngine.showsPortTLSNotice(draft, traits) else { return nil }
        let port = ConnectionEditorEngine.resolvedPort(draft, traits)
        guard let implied = traits.ssl.impliedMode(forPort: port) else { return nil }
        return PortTLSNotice(port: port, impliedMode: implied, sslModeIsDisabled: draft.ssl.mode == .disabled)
    }

    var transportSummary: String {
        ConnectionEditorEngine.transportSummary(draft, traits)
    }

    var tunnelCommandPreview: String? {
        let endpoint = testRecord(testId: connectionId).tunnelForwardEndpoint
        return TunnelCommandBuilder.previewCommand(
            for: draft.tunnelCommand.trimmedConfiguration,
            remoteHost: endpoint.host,
            remotePort: endpoint.port
        )
    }

    // What a password source sees for the values in the form, saved or not.
    func passwordSourceContext() -> ConnectionScriptContext {
        ConnectionScriptContext(connection: testRecord(testId: connectionId))
    }

    func pluginField(_ fieldID: String) -> ConnectionField? {
        traits.field(fieldID)
    }

    func pluginFieldKind(_ fieldID: String) -> PluginFieldKind? {
        guard let field = traits.field(fieldID) else { return nil }
        return PluginFieldKind(field: field, traits: traits)
    }

    // MARK: - Bindings

    func binding<Value>(_ keyPath: WritableKeyPath<ConnectionDraft, Value>) -> Binding<Value> {
        Binding(
            get: { self.draft[keyPath: keyPath] },
            set: { newValue in self.update { $0[keyPath: keyPath] = newValue } }
        )
    }

    func pluginFieldBinding(_ fieldID: String) -> Binding<String> {
        Binding(
            get: { self.draft.fieldValues[fieldID] ?? self.traits.field(fieldID)?.defaultValue ?? "" },
            set: { self.setFieldValue($0, for: fieldID) }
        )
    }

    var portBinding: Binding<String> {
        Binding(get: { self.draft.portText }, set: { self.setPort($0) })
    }

    func hostBinding(undoManager: UndoManager?) -> Binding<String> {
        Binding(get: { self.draft.host }, set: { self.setHost($0, undoManager: undoManager) })
    }

    var sslModeBinding: Binding<SSLMode> {
        Binding(get: { self.draft.ssl.mode }, set: { self.selectSSLMode($0) })
    }

    var transportBinding: Binding<ConnectionTunnelKind?> {
        Binding(get: { self.draft.transport }, set: { self.selectTransport($0) })
    }

    var endpointBinding: Binding<ConnectionDraft.Endpoint> {
        Binding(get: { self.draft.endpoint }, set: { self.selectEndpoint($0) })
    }

    var passwordPromptBinding: Binding<Bool> {
        Binding(get: { self.draft.credentials.promptsForPassword }, set: { self.setPasswordPrompt($0) })
    }

    var credentialModeBinding: Binding<CredentialMode> {
        Binding(get: { self.draft.credentials.mode }, set: { self.setCredentialMode($0) })
    }

    var environmentBinding: Binding<ConnectionEnvironment> {
        Binding(get: { self.draft.environment }, set: { self.setEnvironment($0) })
    }

    var safeModeLevelBinding: Binding<SafeModeLevel> {
        Binding(get: { self.effectiveSafeModeLevel }, set: { self.setSafeModeLevel($0) })
    }

    var manualCommitBinding: Binding<Bool> {
        Binding(get: { self.effectiveManualCommit }, set: { self.setManualCommit($0) })
    }

    var sshProfileBinding: Binding<UUID?> {
        Binding(get: { self.draft.ssh.profileId }, set: { self.selectSSHProfile($0) })
    }

    var sshConfigHostBinding: Binding<String> {
        Binding(get: { self.draft.ssh.selectedConfigHost }, set: { self.selectSSHConfigHost($0) })
    }

    func jumpHostBinding(_ id: UUID) -> Binding<SSHJumpHost> {
        Binding(
            get: { self.draft.ssh.jumpHosts.first { $0.id == id } ?? SSHJumpHost(id: id) },
            set: { self.updateJumpHost($0) }
        )
    }

    func maskingRuleBinding(_ id: UUID) -> Binding<MaskingRule> {
        Binding(
            get: { self.draft.safety.maskingRules.first { $0.id == id } ?? MaskingRule(id: id, pattern: "") },
            set: { self.updateMaskingRule($0) }
        )
    }
}

struct PortTLSNotice: Equatable {
    let port: Int
    let impliedMode: SSLMode
    let sslModeIsDisabled: Bool

    var message: String {
        if sslModeIsDisabled {
            return String(format: String(localized: "Port %lld usually requires TLS, and SSL Mode is Disabled."), Int64(port))
        }
        return String(format: String(localized: "Port %lld uses TLS, so SSL Mode is %@."), Int64(port), impliedMode.displayLabel)
    }

    var actionTitle: String? {
        sslModeIsDisabled ? String(format: String(localized: "Use %@"), impliedMode.displayLabel) : nil
    }
}

enum SocketFileStatus: Equatable {
    case missing
    case notSocket
    case socket

    // stat, not attributesOfItem, which reports a symlink to the socket as a symlink.
    static func of(path: String) -> SocketFileStatus? {
        var info = stat()
        guard stat(path, &info) == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .missing : nil
        }
        return info.st_mode & S_IFMT == S_IFSOCK ? .socket : .notSocket
    }
}

// `ssh -L` needs the socket file itself, while libpq names the directory holding it.
enum SSHForwardSocketAdvice: Equatable {
    case notAbsolute
    case looksLikeDirectory

    static func of(path rawPath: String) -> SSHForwardSocketAdvice? {
        let path = rawPath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        guard path.hasPrefix("/") else { return .notAbsolute }
        return path.hasSuffix("/") ? .looksLikeDirectory : nil
    }
}

enum PluginFieldKind: Equatable {
    case text
    case secure
    case dropdown([ConnectionField.DropdownOption])
    case number
    case toggle
    case stepper(ClosedRange<Int>)
    case hostList
    case attachedDatabases
    case loadableExtensions
    case localDatabaseFile
    case filePath
    case awsProfile

    init(field: ConnectionField, traits: ConnectionTypeTraits) {
        switch field.content {
        case .attachedDatabases:
            self = .attachedDatabases
            return
        case .loadableExtensions:
            self = .loadableExtensions
            return
        case .plain:
            break
        @unknown default:
            break
        }
        if traits.localFilePathField == .additionalField(field.id) {
            self = .localDatabaseFile
            return
        }
        switch field.fieldType {
        case .text:
            if field.dynamicOptions == .awsProfiles {
                self = .awsProfile
            } else if field.id.hasSuffix("FilePath") {
                self = .filePath
            } else {
                self = .text
            }
        case .secure: self = .secure
        case .dropdown(let options): self = .dropdown(options)
        case .number: self = .number
        case .toggle: self = .toggle
        case .stepper(let range): self = .stepper(range.closedRange)
        case .hostList: self = .hostList
        }
    }
}
