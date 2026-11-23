//
//  ConnectionDraft+Mutations.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSSHConfig

// Each coupled edit is one method, so two fields never resolve against the same stale value.
extension ConnectionDraft {
    mutating func setPort(_ text: String, traits: ConnectionTypeTraits) {
        portText = text
        reconcileSSLWithPort(traits: traits)
    }

    mutating func reconcileSSLWithPort(traits: ConnectionTypeTraits) {
        guard ssl.origin != .chosen else { return }
        let resolution = traits.ssl.resolution(forPort: ConnectionEditorEngine.resolvedPort(self, traits))
        ssl.mode = resolution.mode
        ssl.origin = resolution.origin
    }

    mutating func selectSSLMode(_ mode: SSLMode) {
        ssl.mode = mode
        ssl.origin = .chosen
    }

    mutating func applyImportedSSL(_ resolution: SSLModeResolution) {
        ssl.mode = resolution.mode
        ssl.origin = resolution.origin
    }

    // One transport at a time; values a transport owns leave with it when nothing else can reach them.
    mutating func selectTransport(_ kind: ConnectionTunnelKind?) {
        transport = kind
        if kind != .remoteFile {
            ssh.remoteFilePath = ""
        }
        if kind != .ssh {
            sshForwardUnixSocketPath = ""
        }
    }

    // No tunnel reaches a socket file on this Mac, so Socket clears the transport in the same edit.
    mutating func selectEndpoint(_ newEndpoint: Endpoint) {
        guard newEndpoint != endpoint else { return }
        endpoint = newEndpoint
        if newEndpoint == .localSocket {
            selectTransport(nil)
        }
    }

    // Ask Every Time contradicts a stored password and any toggle that supplies the password another way.
    mutating func setPasswordPrompt(_ prompts: Bool, traits: ConnectionTypeTraits) {
        credentials.promptsForPassword = prompts
        guard prompts else { return }
        credentials.password = ""
        for field in traits.fields where field.section == .authentication && field.hidesPassword {
            if case .toggle = field.fieldType, fieldValues[field.id] == "true" {
                fieldValues[field.id] = ""
            }
        }
    }

    mutating func setCredentialMode(_ mode: CredentialMode) {
        credentials.mode = mode
    }

    mutating func setEnvironment(_ newEnvironment: ConnectionEnvironment) {
        environment = newEnvironment
        guard !safety.userSetSafeMode else { return }
        safety.safeModeLevel = Self.defaultSafeModeLevel(for: newEnvironment)
    }

    static func defaultSafeModeLevel(for environment: ConnectionEnvironment) -> SafeModeLevel {
        environment == .production ? .alert : .silent
    }

    // Picking the level a floor already shows keeps the saved choice, which comes back once the floor lifts.
    mutating func setSafeModeLevel(_ level: SafeModeLevel, floor: SafeModeFloor?) {
        let effective = floor?.raising(safety.safeModeLevel) ?? safety.safeModeLevel
        guard level != effective else { return }
        safety.safeModeLevel = level
        safety.userSetSafeMode = true
    }

    mutating func setManualCommit(_ enabled: Bool, traits: ConnectionTypeTraits) {
        guard traits.manualCommitAvailable else { return }
        safety.commitMode = enabled ? .manual : .automatic
    }

    mutating func setFieldValue(_ value: String, for fieldID: String) {
        fieldValues[fieldID] = value
    }

    mutating func forgetAlwaysAllowed(_ tool: String) {
        ai.alwaysAllowedTools.removeAll { $0 == tool }
        ai.revokedTools.insert(tool)
    }

    @discardableResult
    mutating func addMaskingRule() -> UUID {
        let rule = MaskingRule(pattern: "")
        safety.maskingRules.append(rule)
        return rule.id
    }

    mutating func removeMaskingRule(id: UUID) {
        safety.maskingRules.removeAll { $0.id == id }
    }

    mutating func updateMaskingRule(_ rule: MaskingRule) {
        guard let index = safety.maskingRules.firstIndex(where: { $0.id == rule.id }) else { return }
        safety.maskingRules[index] = rule
    }

    mutating func selectSSHProfile(_ id: UUID?, profiles: [SSHProfile]) {
        ssh.profileId = id
        if let id, let profile = profiles.first(where: { $0.id == id }) {
            ssh.profileSnapshot = profile.toSSHConfiguration()
        }
    }

    mutating func selectSSHConfigHost(_ host: String) {
        ssh.selectedConfigHost = host
        if !host.isEmpty {
            ssh.host = host
        }
    }

    @discardableResult
    mutating func addJumpHost() -> UUID {
        let jumpHost = SSHJumpHost()
        ssh.jumpHosts.append(jumpHost)
        return jumpHost.id
    }

    mutating func removeJumpHost(id: UUID) {
        ssh.jumpHosts.removeAll { $0.id == id }
    }

    mutating func updateJumpHost(_ jumpHost: SSHJumpHost) {
        guard let index = ssh.jumpHosts.firstIndex(where: { $0.id == jumpHost.id }) else { return }
        ssh.jumpHosts[index] = jumpHost
    }

    mutating func moveJumpHosts(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted()
        guard !moving.isEmpty, moving.allSatisfy({ ssh.jumpHosts.indices.contains($0) }) else { return }
        let moved = moving.map { ssh.jumpHosts[$0] }
        let shift = moving.filter { $0 < destination }.count
        for index in moving.reversed() {
            ssh.jumpHosts.remove(at: index)
        }
        let insertion = min(max(destination - shift, 0), ssh.jumpHosts.count)
        ssh.jumpHosts.insert(contentsOf: moved, at: insertion)
    }
}
