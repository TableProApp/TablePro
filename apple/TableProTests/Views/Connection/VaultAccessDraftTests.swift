//
//  VaultAccessDraftTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct VaultAccessDraftTests {
    @Test("The profile editor's fields build the role, and reading it back gives the same fields", arguments: [
        VaultAuthMethod.token,
        .appRole(mount: "approle", roleId: "r1", secretIdPath: "~/.vault/secret-id"),
        .appRole(mount: "approle-ci", roleId: "r1", secretIdPath: "/keys/id"),
        .oidc(mount: "oidc", role: ""),
        .oidc(mount: "okta", role: "dba"),
    ])
    func roundTripsThroughTheFields(auth: VaultAuthMethod) {
        let role = VaultDatabaseRole(address: "https://vault.corp:8200", mount: "database", role: "readonly", auth: auth)
        let (kind, value, field) = PasswordSourceKind.decompose(.vaultDatabaseRole(role))

        let rebuilt = kind.source(value: value, field: field, reuseSeconds: nil, vaultAccess: VaultAccessDraft(role))

        #expect(kind == .vaultDatabaseRole)
        #expect(rebuilt == .vaultDatabaseRole(role))
    }

    @Test("Blank fields fall back to VAULT_ADDR and the method's default mount")
    func defaults() {
        var draft = VaultAccessDraft()
        draft.address = "  "
        draft.selectMethod(.oidc)
        #expect(draft.trimmedAddress == nil)
        #expect(draft.auth == .oidc(mount: "oidc", role: ""))
    }

    @Test("Switching method clears the auth mount typed for the other one")
    func switchingMethodClearsMount() {
        var draft = VaultAccessDraft()
        draft.selectMethod(.appRole)
        draft.mount = "approle-ci"
        draft.selectMethod(.oidc)
        #expect(draft.mount.isEmpty)
        #expect(draft.auth == .oidc(mount: "oidc", role: ""))
    }

    @Test("AppRole is incomplete until it has a role ID and a secret ID file")
    func appRoleCompleteness() {
        var draft = VaultAccessDraft()
        draft.selectMethod(.appRole)
        #expect(!draft.isComplete)
        draft.roleId = "r1"
        #expect(!draft.isComplete)
        draft.secretIdPath = "~/.vault/secret-id"
        #expect(draft.isComplete)
    }

    @Test("Only a Vault role answers for the username")
    func suppliesUsername() {
        #expect(PasswordSourceKind.allCases.filter(\.suppliesUsername) == [.vaultDatabaseRole])
    }

    @Test("An unchanged role read back from a profiles file something else wrote is refused a test")
    func untrustedRoleIsRefused() {
        let stored = PasswordSource.vaultDatabaseRole(
            VaultDatabaseRole(address: "https://evil.example", mount: "database", role: "ro", auth: .token)
        )
        #expect(CredentialProfileEditorSheet.testRefusal(for: stored, storedSource: stored, storeIsTrusted: false)
            == .profileStoreNotTrusted)

        let edited = PasswordSource.vaultDatabaseRole(
            VaultDatabaseRole(address: "https://vault.corp", mount: "database", role: "ro", auth: .token)
        )
        #expect(CredentialProfileEditorSheet.testRefusal(for: edited, storedSource: stored, storeIsTrusted: false) == nil)
    }

    @Test("A connection with a Vault role signs in with a lease; others do not")
    func signsInWithLease() {
        var connection = TestFixtures.makeConnection()
        #expect(!ConnectionCredentialResolver.signsInWithLease(connection))
        connection.passwordSource = .vaultDatabaseRole(VaultDatabaseRole(mount: "database", role: "ro"))
        #expect(ConnectionCredentialResolver.signsInWithLease(connection))
        connection.passwordSource = .env(variable: "DB_PASSWORD")
        #expect(!ConnectionCredentialResolver.signsInWithLease(connection))
    }

    @Test("A profile shows a Vault role by name")
    func profileSummary() {
        let profile = CredentialProfile(
            name: "Reader",
            passwordMode: .source(.vaultDatabaseRole(VaultDatabaseRole(mount: "database", role: "ro")))
        )
        #expect(profile.summary == String(localized: "Vault database role"))
    }
}
