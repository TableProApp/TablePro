import Foundation
import TableProDatabase
import TableProModels
import TableProSSHTransport
import Testing

@testable import TableProMobile

@MainActor
@Suite("Connection form two-factor sign-in")
struct ConnectionFormViewModelTOTPTests {
    private func tunnelled(_ configure: (inout SSHConfiguration) -> Void = { _ in }) -> DatabaseConnection {
        var ssh = SSHConfiguration(host: "bastion.example.com", username: "deploy", authMethod: .password)
        configure(&ssh)
        return DatabaseConnection(
            name: "Bastion",
            type: .postgresql,
            host: "10.0.0.5",
            port: 5_432,
            sshEnabled: true,
            sshConfiguration: ssh
        )
    }

    @Test("The Mac's TOTP settings show in the form and go back as they were when untouched")
    func macSettingsRoundTrip() {
        let connection = tunnelled {
            $0.totpMode = "auto_generate"
            $0.totpAlgorithm = "SHA256"
            $0.totpDigits = 8
            $0.totpPeriod = 60
        }
        let form = ConnectionFormViewModel(editing: connection)

        #expect(form.totpMode == .autoGenerate)
        #expect(form.totpAlgorithm == .sha256)
        #expect(form.totpDigits == 8)
        #expect(form.totpPeriod == 60)

        form.sshPort = "2222"
        let saved = form.applyingEdits(to: connection).sshConfiguration
        #expect(saved?.totpMode == "auto_generate")
        #expect(saved?.totpAlgorithm == "SHA256")
        #expect(saved?.totpDigits == 8)
    }

    @Test("Choosing Auto Generate writes the Mac's spelling")
    func choiceWritesMacSpelling() {
        let connection = tunnelled()
        let form = ConnectionFormViewModel(editing: connection)

        form.totpMode = .autoGenerate
        form.totpDigits = 8
        let saved = form.applyingEdits(to: connection).sshConfiguration

        #expect(saved?.totpMode == TOTPMode.autoGenerate.rawValue)
        #expect(saved?.totpAlgorithm == TOTPAlgorithm.sha1.rawValue)
        #expect(saved?.totpDigits == 8)
        #expect(saved?.totpPeriod == 30)
    }

    @Test("The stored secret loads under the Mac's account, and a new one is written and tested")
    func secretLoadsAndWrites() async {
        let connection = tunnelled { $0.totpMode = "auto_generate" }
        let store = MockSecureStore()
        let account = "com.TablePro.totpsecret.\(connection.id.uuidString)"
        store.seed(account, "JBSWY3DPEHPK3PXP")
        let form = ConnectionFormViewModel(editing: connection)
        await form.loadStoredCredentials(secureStore: store)

        #expect(form.totpSecret == "JBSWY3DPEHPK3PXP")
        #expect(form.secretWrites.totpSecret == nil)

        form.totpSecret = "KRSXG5CTMVRXEZLU"
        #expect(form.secretWrites.totpSecret == "KRSXG5CTMVRXEZLU")
        #expect(form.reconnectsAfterSave)
        #expect(form.testSecrets(for: connection.id)[account] == "KRSXG5CTMVRXEZLU")
    }

    @Test("Every method but None offers two-factor sign-in")
    func twoFactorFollowsTheMethod() {
        let form = ConnectionFormViewModel(editing: tunnelled())

        for method in [SSHConfiguration.SSHAuthMethod.password, .privateKey, .keyboardInteractive] {
            form.sshAuthMethod = method
            #expect(form.offersTwoFactor)
        }
        form.sshAuthMethod = .none
        #expect(!form.offersTwoFactor)
    }
}
