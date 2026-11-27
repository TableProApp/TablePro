//
//  SecretWritePlan.swift
//  TablePro
//

import Foundation
import TableProConnectionLibrary
import TableProPluginKit
import TableProSSHConfig
import TableProSSHTransport

struct SecretWritePlan: Equatable, Sendable {
    enum Item: Hashable, Sendable {
        case password
        case sshPassword
        case sshKeyPassphrase
        case totpSecret
        case sslClientKeyPassphrase
        case cloudflareTokenId
        case cloudflareTokenSecret
        case cloudSQLServiceAccountKey
        case socksPassword
        case pluginField(String)
    }

    struct Write: Equatable, Sendable {
        let item: Item
        let value: String
    }

    var writes: [Write] = []
    // Deferred by the staging until the record is on disk; a key whose read failed at load is never deleted.
    var stagedDeletes: [Item] = []
    // Deliberate clears the user made, run once the record is on disk.
    var deletesAfterRecord: [Item] = []

    func writes(of item: Item) -> String? {
        writes.first { $0.item == item }?.value
    }

    enum Disposition: Equatable {
        case untouched
        case write(String)
        case delete
    }

    // A delete after the record runs last, and a write cancels a staged delete of the same key.
    func disposition(of item: Item) -> Disposition {
        if deletesAfterRecord.contains(item) { return .delete }
        if let value = writes(of: item) { return .write(value) }
        return stagedDeletes.contains(item) ? .delete : .untouched
    }
}

extension ConnectionEditorEngine {
    // The exact declared secure fields of the type being saved and of the type it started as.
    static func secureFieldsOwnedByForm(
        _ traits: ConnectionTypeTraits,
        originalTraits: ConnectionTypeTraits?
    ) -> [ConnectionField] {
        var fields = traits.fields.filter(\.isSecure)
        guard let originalTraits, originalTraits.type != traits.type else { return fields }
        let known = Set(fields.map(\.id))
        fields += originalTraits.fields.filter { $0.isSecure && !known.contains($0.id) }
        return fields
    }

    static func secretPlan(
        _ draft: ConnectionDraft,
        _ traits: ConnectionTypeTraits,
        originalTraits: ConnectionTypeTraits?,
        _ context: EditorContext
    ) -> SecretWritePlan {
        let draft = normalized(draft, traits)
        var plan = SecretWritePlan()
        func write(_ item: SecretWritePlan.Item, _ value: String) {
            plan.writes.append(SecretWritePlan.Write(item: item, value: value))
        }

        let profileOwned = Set(draft.credentials.mode.profileId.flatMap { context.credentialProfile($0)?.secureFieldIds } ?? [])
        for field in secureFieldsOwnedByForm(traits, originalTraits: originalTraits) where !profileOwned.contains(field.id) {
            let value = draft.fieldValues[field.id] ?? ""
            if value.isEmpty {
                plan.stagedDeletes.append(.pluginField(field.id))
            } else {
                write(.pluginField(field.id), value)
            }
        }
        // An installed plugin older than the field still must not leave the token in the record.
        let sessionTokenId = ConnectionSecretOptions.mongoSessionTokenFieldId
        if let token = draft.fieldValues[sessionTokenId], !token.isEmpty {
            write(.pluginField(sessionTokenId), token)
        }

        // A linked connection holds no secret of its own: the profile owns it, so rotating it is one edit.
        if let profileId = draft.credentials.mode.profileId {
            plan.deletesAfterRecord.append(.password)
            for fieldId in context.credentialProfile(profileId)?.secureFieldIds ?? [] {
                plan.deletesAfterRecord.append(.pluginField(fieldId))
            }
        } else if effectivePromptForPassword(draft, traits) || clearsStoredPassword(draft, traits) {
            plan.deletesAfterRecord.append(.password)
        } else if !draft.credentials.password.isEmpty {
            write(.password, draft.credentials.password)
        }

        planSSHSecrets(draft, context, into: &plan)

        if !draft.ssl.clientKeyPassphrase.isEmpty,
           !draft.ssl.clientKeyPath.trimmingCharacters(in: .whitespaces).isEmpty {
            write(.sslClientKeyPassphrase, draft.ssl.clientKeyPassphrase)
        } else {
            plan.stagedDeletes.append(.sslClientKeyPassphrase)
        }

        if draft.transport == .cloudflare, draft.cloudflare.authMethod == .serviceToken {
            write(.cloudflareTokenId, draft.cloudflare.serviceTokenId)
            write(.cloudflareTokenSecret, draft.cloudflare.serviceTokenSecret)
        } else {
            plan.stagedDeletes.append(contentsOf: [.cloudflareTokenId, .cloudflareTokenSecret])
        }

        if draft.transport == .cloudSQLProxy, draft.cloudSQLProxy.authMode == .serviceAccountKey,
           draft.cloudSQLProxy.hasServiceAccountKey {
            write(.cloudSQLServiceAccountKey, draft.cloudSQLProxy.serviceAccountKeyJSON)
        } else {
            plan.stagedDeletes.append(.cloudSQLServiceAccountKey)
        }

        if draft.transport == .socksProxy, !draft.socksProxy.password.isEmpty {
            write(.socksPassword, draft.socksProxy.password)
        } else {
            plan.stagedDeletes.append(.socksPassword)
        }
        return plan
    }

    // Save onto a stored record. The draft's own plan deletes every secret its settings leave out, and those settings
    // may be stale: a delete stands only where this editor changed the secret or what owns it since `baseline`, and
    // the merged record keeps no use for it.
    static func secretPlan(
        _ draft: ConnectionDraft,
        _ traits: ConnectionTypeTraits,
        originalTraits: ConnectionTypeTraits?,
        _ context: EditorContext,
        since baseline: ConnectionDraft,
        mergedInto merged: DatabaseConnection
    ) -> SecretWritePlan {
        let mine = secretPlan(draft, traits, originalTraits: originalTraits, context)
        let baselineTraits = baseline.type == traits.type ? traits : originalTraits ?? traits
        let before = secretPlan(baseline, baselineTraits, originalTraits: originalTraits, context)
        let draft = normalized(draft, traits)
        func stands(_ item: SecretWritePlan.Item) -> Bool {
            // A record that still delegates to the profile keeps no copy of its own for the driver to fall back on.
            if delegatesToProfile(item, merged, context) { return true }
            guard mine.disposition(of: item) != before.disposition(of: item) else { return false }
            return secretValue(item, in: draft).isEmpty || !record(merged, uses: item)
        }
        var plan = mine
        plan.writes = mine.writes.filter { !delegatesToProfile($0.item, merged, context) }
        plan.stagedDeletes = mine.stagedDeletes.filter(stands)
        plan.deletesAfterRecord = mine.deletesAfterRecord.filter(stands)
        return plan
    }

    static func secretValue(_ item: SecretWritePlan.Item, in draft: ConnectionDraft) -> String {
        switch item {
        case .password: return draft.credentials.password
        case .sshPassword: return draft.ssh.password
        case .sshKeyPassphrase: return draft.ssh.keyPassphrase
        case .totpSecret: return draft.ssh.totpSecret
        case .sslClientKeyPassphrase: return draft.ssl.clientKeyPassphrase
        case .cloudflareTokenId: return draft.cloudflare.serviceTokenId
        case .cloudflareTokenSecret: return draft.cloudflare.serviceTokenSecret
        case .cloudSQLServiceAccountKey: return draft.cloudSQLProxy.serviceAccountKeyJSON
        case .socksPassword: return draft.socksProxy.password
        case .pluginField(let fieldId): return draft.fieldValues[fieldId] ?? ""
        }
    }

    static func delegatesToProfile(_ item: SecretWritePlan.Item, _ record: DatabaseConnection, _ context: EditorContext) -> Bool {
        guard let profileId = record.credentialMode.profileId else { return false }
        switch item {
        case .password:
            return true
        case .pluginField(let fieldId):
            return context.credentialProfile(profileId)?.secureFieldIds.contains(fieldId) == true
        default:
            return false
        }
    }

    // Whether a stored record still has a place for the secret, whatever value it holds.
    static func record(_ record: DatabaseConnection, uses item: SecretWritePlan.Item) -> Bool {
        switch item {
        case .password:
            return record.credentialMode.profileId == nil && !record.promptForPassword
        case .pluginField:
            return record.credentialMode.profileId == nil
        case .sshPassword, .sshKeyPassphrase, .totpSecret:
            guard case .inline(let config) = record.sshTunnelMode else { return false }
            switch item {
            case .sshPassword: return config.authMethod == .password || config.authMethod == .keyboardInteractive
            case .sshKeyPassphrase: return config.authMethod == .privateKey
            default: return config.totpMode == .autoGenerate
            }
        case .sslClientKeyPassphrase:
            return !record.sslConfig.clientKeyPath.trimmingCharacters(in: .whitespaces).isEmpty
        case .cloudflareTokenId, .cloudflareTokenSecret:
            guard case .inline(let config) = record.cloudflareTunnelMode else { return false }
            return config.authMethod == .serviceToken
        case .cloudSQLServiceAccountKey:
            guard case .inline(let config) = record.cloudSQLProxyMode else { return false }
            return config.authMode == .serviceAccountKey
        case .socksPassword:
            guard case .inline = record.socksProxyMode else { return false }
            return true
        }
    }

    // A profile this Mac cannot resolve keeps its link and every secret: nothing here may convert or clear it.
    private static func planSSHSecrets(_ draft: ConnectionDraft, _ context: EditorContext, into plan: inout SecretWritePlan) {
        switch sshResolution(draft, context) {
        case .inline:
            let ssh = draft.ssh
            if (ssh.authMethod == .password || ssh.authMethod == .keyboardInteractive) && !ssh.password.isEmpty {
                plan.writes.append(SecretWritePlan.Write(item: .sshPassword, value: ssh.password))
            } else if ssh.clearsStoredPassword {
                plan.deletesAfterRecord.append(.sshPassword)
            }
            if ssh.authMethod == .privateKey && !ssh.keyPassphrase.isEmpty {
                plan.writes.append(SecretWritePlan.Write(item: .sshKeyPassphrase, value: ssh.keyPassphrase))
            } else if ssh.clearsStoredKeyPassphrase {
                plan.deletesAfterRecord.append(.sshKeyPassphrase)
            }
            if ssh.totpMode == .autoGenerate && !ssh.totpSecret.isEmpty {
                plan.writes.append(SecretWritePlan.Write(item: .totpSecret, value: ssh.totpSecret))
            } else {
                plan.stagedDeletes.append(.totpSecret)
            }
        case .profile, .disabled:
            plan.stagedDeletes.append(contentsOf: [.sshPassword, .sshKeyPassphrase, .totpSecret])
        case .unresolvedProfile:
            break
        }
    }
}
