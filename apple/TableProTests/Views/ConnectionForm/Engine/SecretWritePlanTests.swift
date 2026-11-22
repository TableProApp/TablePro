//
//  SecretWritePlanTests.swift
//  TableProTests
//

import Foundation
import TableProConnectionLibrary
import TableProPluginKit
import TableProSSHConfig
import Testing

@testable import TablePro

@MainActor
struct SecretWritePlanTests {
    private func traits(_ type: DatabaseType) -> ConnectionTypeTraits {
        ConnectionTypeTraits.live(for: type, pluginManager: .shared)
    }

    private func plan(_ draft: ConnectionDraft, _ traits: ConnectionTypeTraits, _ context: EditorContext = EditorContext())
        -> SecretWritePlan {
        ConnectionEditorEngine.secretPlan(draft, traits, originalTraits: traits, context)
    }

    @Test("Emptying a stored password deletes it once the record is on disk")
    func clearedPasswordIsDeleted() {
        let mysql = traits(.mysql)
        var draft = ConnectionDraft.new(type: .mysql, traits: mysql)
        draft.credentials.storedPasswordState = .stored
        draft.credentials.password = ""
        let plan = plan(draft, mysql)
        #expect(plan.deletesAfterRecord.contains(.password))
        #expect(plan.writes(of: .password) == nil)
    }

    @Test("An empty field over a password that could not be read deletes nothing")
    func unreadablePasswordIsKept() {
        let mysql = traits(.mysql)
        var draft = ConnectionDraft.new(type: .mysql, traits: mysql)
        draft.credentials.storedPasswordState = .unreadable
        let plan = plan(draft, mysql)
        #expect(!plan.deletesAfterRecord.contains(.password))
        #expect(!plan.stagedDeletes.contains(.password))
    }

    @Test("A typed password is written")
    func typedPasswordIsWritten() {
        let mysql = traits(.mysql)
        var draft = ConnectionDraft.new(type: .mysql, traits: mysql)
        draft.credentials.password = "hunter2"
        #expect(plan(draft, mysql).writes(of: .password) == "hunter2")
    }

    @Test("A linked credential profile clears the connection's password and the profile's secure fields")
    func linkedProfileClearsOwnSecrets() {
        let mysql = traits(.mysql)
        let profile = CredentialProfile(name: "Shared", secureFieldIds: ["awsSecretAccessKey"])
        var context = EditorContext()
        context.credentialProfiles = [profile]
        var draft = ConnectionDraft.new(type: .mysql, traits: mysql)
        draft.credentials.password = "hunter2"
        draft.setCredentialMode(.profile(id: profile.id))
        let plan = plan(draft, mysql, context)
        #expect(plan.deletesAfterRecord.contains(.password))
        #expect(plan.deletesAfterRecord.contains(.pluginField("awsSecretAccessKey")))
        #expect(plan.writes(of: .password) == nil)
    }

    @Test("A linked profile's secure field typed on the connection is not stored as a copy of its own")
    func profileOwnedFieldIsNotWrittenOnSave() {
        let postgres = traits(.postgresql)
        let profile = CredentialProfile(name: "Shared", secureFieldIds: ["awsSecretAccessKey"])
        var context = EditorContext()
        context.credentialProfiles = [profile]
        var baseline = ConnectionDraft.new(type: .postgresql, traits: postgres)
        baseline.setCredentialMode(.profile(id: profile.id))
        var draft = baseline
        draft.fieldValues["awsSecretAccessKey"] = "typed"
        var merged = DatabaseConnection(name: "Orders", host: "db.example.com", port: 5_432, username: "app", type: .postgresql)
        merged.credentialMode = .profile(id: profile.id)
        let plan = ConnectionEditorEngine.secretPlan(
            draft, postgres, originalTraits: postgres, context, since: baseline, mergedInto: merged
        )
        #expect(plan.writes(of: .pluginField("awsSecretAccessKey")) == nil)
        #expect(plan.deletesAfterRecord.contains(.pluginField("awsSecretAccessKey")))
    }

    @Test("An SSH profile this Mac cannot resolve keeps its link and deletes no SSH secret")
    func unresolvedSSHProfileTouchesNothing() {
        let mysql = traits(.mysql)
        var draft = ConnectionDraft.new(type: .mysql, traits: mysql)
        draft.selectTransport(.ssh)
        draft.ssh.profileId = UUID()
        draft.ssh.profileSnapshot = SSHConfiguration(enabled: true, host: "bastion.example.com")
        let plan = plan(draft, mysql)
        let sshItems: [SecretWritePlan.Item] = [.sshPassword, .sshKeyPassphrase, .totpSecret]
        for item in sshItems {
            #expect(!plan.stagedDeletes.contains(item))
            #expect(!plan.deletesAfterRecord.contains(item))
            #expect(plan.writes(of: item) == nil)
        }
        let edits = ConnectionEditorEngine.edits(draft, mysql, originalTraits: mysql, EditorContext())
        guard case .profile(let id, let snapshot) = edits.sshTunnelMode else {
            Issue.record("An unresolved profile was converted: \(edits.sshTunnelMode)")
            return
        }
        #expect(id == draft.ssh.profileId)
        #expect(snapshot.host == "bastion.example.com")
        #expect(edits.sshProfileId == draft.ssh.profileId)
    }

    @Test("A resolved SSH profile clears the connection's own SSH secrets")
    func resolvedSSHProfileClearsInlineSecrets() {
        let mysql = traits(.mysql)
        let profile = SSHProfile(name: "Bastion", host: "bastion.example.com")
        var context = EditorContext()
        context.sshProfiles = [profile]
        var draft = ConnectionDraft.new(type: .mysql, traits: mysql)
        draft.selectTransport(.ssh)
        draft.selectSSHProfile(profile.id, profiles: [profile])
        let plan = plan(draft, mysql, context)
        #expect(plan.stagedDeletes.contains(.sshPassword))
        #expect(plan.stagedDeletes.contains(.sshKeyPassphrase))
    }

    @Test("An SSL key passphrase is written only beside a client key, and cleared without one")
    func sslKeyPassphraseNeedsAClientKey() {
        let postgres = traits(.postgresql)
        var draft = ConnectionDraft.new(type: .postgresql, traits: postgres)
        draft.ssl.clientKeyPassphrase = "key-secret"
        let withoutKey = plan(draft, postgres)
        #expect(withoutKey.writes(of: .sslClientKeyPassphrase) == nil)
        #expect(withoutKey.stagedDeletes.contains(.sslClientKeyPassphrase))

        draft.ssl.clientKeyPath = "/Users/alice/client.key"
        #expect(plan(draft, postgres).writes(of: .sslClientKeyPassphrase) == "key-secret")
    }

    @Test("A secure field outside Authentication is written like any other")
    func secureFieldInAnySectionIsWritten() {
        var traits = ConnectionTypeTraits(type: DatabaseType(rawValue: "Probe"))
        traits.fields = [ConnectionField(id: "vaultToken", label: "Vault Token", secure: true, section: .advanced)]
        var draft = ConnectionDraft.new(type: traits.type, traits: traits)
        draft.setFieldValue("s3cret", for: "vaultToken")
        #expect(plan(draft, traits).writes(of: .pluginField("vaultToken")) == "s3cret")
        #expect(ConnectionEditorEngine.edits(draft, traits, originalTraits: nil, EditorContext()).additionalFields["vaultToken"] == nil)
    }

    @Test("A retype clears the secure fields of the type the connection started as")
    func retypeClearsOriginalSecureFields() {
        let snowflake = traits(.snowflake)
        let mysql = traits(.mysql)
        let secureIds = snowflake.declaredSecureFieldIds.filter { mysql.field($0) == nil }
        guard let fieldId = secureIds.first else { return }
        let draft = ConnectionDraft.new(type: .mysql, traits: mysql)
        let plan = ConnectionEditorEngine.secretPlan(draft, mysql, originalTraits: snowflake, EditorContext())
        #expect(plan.stagedDeletes.contains(.pluginField(fieldId)))
    }
}
