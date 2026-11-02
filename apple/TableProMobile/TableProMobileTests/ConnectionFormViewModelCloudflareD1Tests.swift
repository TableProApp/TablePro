import Foundation
@testable import TableProMobile
import TableProModels
import Testing

@MainActor
struct ConnectionFormViewModelCloudflareD1Tests {
    private let fixture: AppStateFixture

    init() throws {
        fixture = try AppStateFixture()
    }

    // A Mac `d1://` import, which writes the account id to Host as well as to the plugin's field.
    private func macConnection() -> DatabaseConnection {
        DatabaseConnection(
            name: "Edge",
            type: .cloudflareD1,
            host: "b5ad7a2e0123",
            port: 0,
            database: "shop",
            additionalFields: [
                "cfAccountId": "b5ad7a2e0123",
                "connectTimeout": "15000"
            ]
        )
    }

    private func newD1Form() -> ConnectionFormViewModel {
        let viewModel = fixture.makeFormViewModel()
        viewModel.type = .cloudflareD1
        return viewModel
    }

    @Test("Save needs an Account ID and a database, and no token, since an edit keeps the stored one")
    func canSaveNeedsAccountAndDatabase() {
        let viewModel = newD1Form()
        #expect(!viewModel.canSave)

        viewModel.cloudflareAccountId = " \n"
        viewModel.database = "shop"
        #expect(!viewModel.canSave)

        viewModel.cloudflareAccountId = "b5ad7a2e0123"
        viewModel.database = ""
        #expect(!viewModel.canSave)

        viewModel.database = "shop"
        #expect(viewModel.password.isEmpty)
        #expect(viewModel.canSave)
    }

    @Test("The Account ID is saved trimmed under the Mac plugin's key and opens again in the form")
    func accountIdRoundTrips() {
        let viewModel = newD1Form()
        viewModel.cloudflareAccountId = " b5ad7a2e0123\n"
        viewModel.database = "shop"

        let built = viewModel.buildConnection()
        let reopened = fixture.makeFormViewModel(editing: built)

        #expect(built.additionalFields["cfAccountId"] == "b5ad7a2e0123")
        #expect(reopened.cloudflareAccountId == "b5ad7a2e0123")
        #expect(reopened.cloudflareD1Credentials.accountId == "b5ad7a2e0123")
    }

    @Test("A rename keeps the Account ID, the Mac's other fields and the Host the Mac wrote")
    func renameKeepsTheMacFields() {
        let stored = macConnection()
        let viewModel = fixture.makeFormViewModel(editing: stored)

        viewModel.name = "Edge Store"
        let saved = viewModel.applyingEdits(to: stored)

        #expect(viewModel.cloudflareAccountId == "b5ad7a2e0123")
        #expect(saved.name == "Edge Store")
        #expect(saved.additionalFields == stored.additionalFields)
        #expect(saved.host == stored.host)
        #expect(saved.database == "shop")
    }

    @Test("An untouched D1 form has no changes and hands the record back as it is")
    func untouchedFormIsClean() {
        let stored = macConnection()
        let viewModel = fixture.makeFormViewModel(editing: stored)

        #expect(!viewModel.hasChanges)
        #expect(viewModel.applyingEdits(to: stored) == stored)
    }

    @Test("A changed Account ID is a change, is saved, and redials an open session")
    func changedAccountIdRedials() {
        let stored = macConnection()
        let viewModel = fixture.makeFormViewModel(editing: stored)

        viewModel.cloudflareAccountId = "c0ffee000000"
        let saved = viewModel.applyingEdits(to: stored)

        #expect(viewModel.hasChanges)
        #expect(saved.additionalFields["cfAccountId"] == "c0ffee000000")
        #expect(saved.additionalFields["connectTimeout"] == "15000")
        #expect(viewModel.redialsAfterSave(over: stored))

        viewModel.cloudflareAccountId = "b5ad7a2e0123"
        #expect(!viewModel.hasChanges)
    }

    @Test("The API token is the connection's password, stored where the Mac keeps it")
    func tokenIsThePassword() async throws {
        let store = MockSecureStore()
        let appState = fixture.makeState(syncEnabled: false, secureStore: store)
        let viewModel = newD1Form()
        viewModel.cloudflareAccountId = "b5ad7a2e0123"
        viewModel.password = "cf-token"
        viewModel.database = "shop"
        let testId = UUID()

        #expect(viewModel.cloudflareD1Credentials == CloudflareD1Credentials(accountId: "b5ad7a2e0123", apiToken: "cf-token"))
        #expect(viewModel.testSecrets(for: testId)["com.TablePro.password.\(testId.uuidString)"] == "cf-token")

        let savedId = try #require(await viewModel.save(appState: appState, secureStore: store))

        #expect(try store.retrieve(forKey: "com.TablePro.password.\(savedId.uuidString)") == "cf-token")
    }

    @Test("A D1 connection with no name is named after its database")
    func nameDefaultsToTheDatabase() {
        let viewModel = newD1Form()
        viewModel.cloudflareAccountId = "b5ad7a2e0123"
        viewModel.database = "shop"

        #expect(viewModel.edits.name == "shop")
        #expect(viewModel.buildConnection().name == "shop")
    }

    @Test("D1 writes no SSL settings, whatever the form held for the previous type")
    func noSSLWritten() {
        let viewModel = fixture.makeFormViewModel()
        viewModel.sslMode = .require
        viewModel.type = .cloudflareD1
        viewModel.cloudflareAccountId = "b5ad7a2e0123"
        viewModel.database = "shop"

        let built = viewModel.buildConnection()

        #expect(viewModel.edits.sslMode == nil)
        #expect(!viewModel.usesCertificateSection)
        #expect(!built.sslEnabled)
        #expect(built.sslConfiguration == nil)
    }

    @Test("D1 stores no host, port or username, even ones typed for the previous type")
    func noServerFieldsWritten() {
        let viewModel = fixture.makeFormViewModel()
        viewModel.host = "db.example.com"
        viewModel.port = "3307"
        viewModel.username = "root"
        viewModel.type = .cloudflareD1
        viewModel.cloudflareAccountId = "b5ad7a2e0123"
        viewModel.database = "shop"

        let built = viewModel.buildConnection()

        #expect(built.host == "")
        #expect(built.port == 0)
        #expect(built.username == "")
    }

    @Test("A MySQL record switched to D1 drops its host, port and username")
    func switchedRecordDropsServerFields() {
        let stored = DatabaseConnection(
            name: "Shop", type: .mysql, host: "10.0.0.5", port: 3_306, username: "root", database: "shop"
        )
        let viewModel = fixture.makeFormViewModel(editing: stored)

        viewModel.type = .cloudflareD1
        viewModel.cloudflareAccountId = "b5ad7a2e0123"
        viewModel.database = "shop"
        let saved = viewModel.applyingEdits(to: stored)

        #expect(saved.type == .cloudflareD1)
        #expect(saved.host == "")
        #expect(saved.port == 0)
        #expect(saved.username == "")
        #expect(saved.additionalFields["cfAccountId"] == "b5ad7a2e0123")
    }

    @Test(
        "Switching to a type with no network transport turns SSH off, since its SSH section is hidden",
        arguments: [DatabaseType.cloudflareD1, .sqlite, .duckdb]
    )
    func typeChangeTurnsSSHOff(type: DatabaseType) {
        let viewModel = fixture.makeFormViewModel()
        viewModel.host = "10.0.0.5"
        viewModel.sshEnabled = true
        viewModel.sshHost = "bastion.example.com"
        viewModel.sshUsername = "deploy"

        viewModel.type = type
        viewModel.database = "/tmp/shop.db"
        viewModel.cloudflareAccountId = "b5ad7a2e0123"
        let built = viewModel.buildConnection()

        #expect(!viewModel.sshEnabled)
        #expect(viewModel.edits.sshTunnel == nil)
        #expect(!built.sshEnabled)
    }

    @Test("Switching between network types keeps the tunnel on")
    func networkTypeChangeKeepsSSH() {
        let viewModel = fixture.makeFormViewModel()
        viewModel.sshEnabled = true
        viewModel.sshHost = "bastion.example.com"

        viewModel.type = .postgresql

        #expect(viewModel.sshEnabled)
        #expect(viewModel.hasNetworkTransport)
    }

    @Test("A synced D1 record with a tunnel opens with it off, so Test Connection dials no SSH")
    func syncedTunnelOpensOff() {
        var stored = macConnection()
        stored.sshEnabled = true
        stored.sshConfiguration = SSHConfiguration(host: "bastion.example.com", username: "deploy")
        let viewModel = fixture.makeFormViewModel(editing: stored)

        #expect(!viewModel.sshEnabled)
        #expect(!viewModel.hasNetworkTransport)
        #expect(!viewModel.buildConnection().sshEnabled)
        #expect(!viewModel.hasChanges)
    }
}
