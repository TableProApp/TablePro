import Foundation
import TableProSSHConfig
import Testing

@testable import TablePro

// A secret that came out of a Keychain must ask for authentication before the Show button reveals it.
struct SSHSecretRevealProvenanceTests {
    @Test func profileSecretsStayProtectedAfterSwitchingToInline() {
        var draft = ConnectionDraft(type: .postgresql)
        draft.transport = .ssh
        draft.ssh.profileId = UUID()
        draft.ssh.adoptKeychainSecrets(password: "hunter2", keyPassphrase: "phrase", totpSecret: "JBSWY3DP")

        draft.selectSSHProfile(nil, profiles: [])

        #expect(draft.ssh.password == "hunter2")
        #expect(draft.ssh.keyPassphrase == "phrase")
        #expect(draft.ssh.totpSecret == "JBSWY3DP")
        #expect(draft.ssh.savedSecrets == [.password, .keyPassphrase, .totpSecret])
    }

    @Test func emptyProfileSecretsAreNotProtected() {
        var ssh = SSHDraft()
        ssh.adoptKeychainSecrets(password: "hunter2", keyPassphrase: "", totpSecret: nil)

        #expect(ssh.savedSecrets == [.password])
    }

    // The old form cleared its fields with the tunnel; this one keeps them, so the guard stays with them.
    @Test func turningTheTransportOffKeepsTheValuesProtected() {
        var draft = ConnectionDraft(type: .postgresql)
        draft.transport = .ssh
        draft.ssh.adoptKeychainSecrets(password: "hunter2", keyPassphrase: "phrase", totpSecret: "JBSWY3DP")

        draft.selectTransport(nil)
        draft.selectTransport(.ssh)

        #expect(draft.ssh.password == "hunter2")
        #expect(draft.ssh.savedSecrets == [.password, .keyPassphrase, .totpSecret])
    }

    @Test func retypingTheConnectionKeepsTheValuesProtected() {
        let mysql = ConnectionTypeTraits(type: .mysql)
        let mariadb = ConnectionTypeTraits(type: .mariadb)
        var draft = ConnectionDraft(type: .mysql)
        draft.ssh.adoptKeychainSecrets(password: "hunter2", keyPassphrase: nil, totpSecret: nil)

        draft.retype(to: mariadb, from: mysql)

        #expect(draft.ssh.password == "hunter2")
        #expect(draft.ssh.savedSecrets == [.password])
    }

    @Test func secretsTypedHereAreNotProtected() {
        var ssh = SSHDraft()
        ssh.password = "typed"
        ssh.keyPassphrase = "typed"
        ssh.totpSecret = "JBSWY3DP"

        #expect(ssh.savedSecrets.isEmpty)
    }

    @Test func filledSecretsNamesOnlyNonEmptyValues() {
        var draft = SSHServerDraft()
        draft.password = "hunter2"
        draft.totpSecret = "JBSWY3DP"

        #expect(draft.filledSecrets == [.password, .totpSecret])
    }
}
