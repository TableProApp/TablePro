import Foundation
import TableProSSHConfig
import Testing

@testable import TablePro

// A secret that came out of a Keychain must ask for authentication before the Show toggle reveals it.
struct SSHSecretRevealProvenanceTests {
    @Test func profileSecretsStayProtectedAfterSwitchingToInline() {
        var state = SSHTunnelFormState()
        state.enabled = true
        state.profileId = UUID()
        state.adoptProfileSecrets(password: "hunter2", keyPassphrase: "phrase", totpSecret: "JBSWY3DP")

        state.profileId = nil

        #expect(state.savedSecrets == [.password, .keyPassphrase, .totpSecret])
    }

    @Test func emptyProfileSecretsAreNotProtected() {
        var state = SSHTunnelFormState()
        state.adoptProfileSecrets(password: "hunter2", keyPassphrase: "", totpSecret: "")

        #expect(state.savedSecrets == [.password])
    }

    @Test func disablingTheTunnelDropsProfileProvenance() {
        var state = SSHTunnelFormState()
        state.adoptProfileSecrets(password: "hunter2", keyPassphrase: "phrase", totpSecret: "JBSWY3DP")

        state.disable()

        #expect(state.savedSecrets.isEmpty)
    }

    @Test func filledSecretsNamesOnlyNonEmptyValues() {
        var draft = SSHServerDraft()
        draft.password = "hunter2"
        draft.totpSecret = "JBSWY3DP"

        #expect(draft.filledSecrets == [.password, .totpSecret])
    }
}
