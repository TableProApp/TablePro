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

        for field in secureFieldsOwnedByForm(traits, originalTraits: originalTraits) {
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
