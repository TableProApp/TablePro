import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
import TableProOracleCore
import Testing

@MainActor
@Suite("Connection form changes")
struct ConnectionFormViewModelChangesTests {
    private let certificates = InMemoryCertificateStore()
    private let fixture: AppStateFixture

    init() throws {
        fixture = try AppStateFixture()
    }

    private func form(editing connection: DatabaseConnection? = nil) -> ConnectionFormViewModel {
        fixture.makeFormViewModel(editing: connection, certificateStore: certificates)
    }

    private func makeAppState(holding connection: DatabaseConnection) -> AppState {
        let state = fixture.makeState(syncEnabled: false)
        #expect(state.addConnection(connection))
        return state
    }

    private func seededStore(for connection: DatabaseConnection) -> MockSecureStore {
        let store = MockSecureStore()
        let suffix = connection.id.uuidString
        store.seed("com.TablePro.password.\(suffix)", "stored")
        store.seed("com.TablePro.sshpassword.\(suffix)", "tunnel")
        store.seed("com.TablePro.keypassphrase.\(suffix)", "unlock")
        return store
    }

    private func postgres() -> DatabaseConnection {
        DatabaseConnection(
            name: "Prod", type: .postgresql, host: "db.example.com", port: 5_432,
            username: "app", database: "app", sslEnabled: true,
            sslConfiguration: SSLConfiguration(
                mode: .verifyFull,
                caCertificatePath: "/ca.pem",
                clientCertificatePath: "/client.pem",
                clientKeyPath: "/client.key"
            )
        )
    }

    private func tunnel(authMethod: SSHConfiguration.SSHAuthMethod, enabled: Bool = true) -> DatabaseConnection {
        DatabaseConnection(
            name: "Tunnelled", type: .mysql, host: "10.0.0.5", port: 3_306, username: "app",
            database: "shop", sshEnabled: enabled,
            sshConfiguration: SSHConfiguration(host: "bastion", port: 22, username: "deploy", authMethod: authMethod)
        )
    }

    private func existingConnections() -> [DatabaseConnection] {
        [
            postgres(),
            DatabaseConnection(
                name: "Reports", type: .mssql, host: "reports", port: 1_433, username: "sa",
                database: "reporting", sslEnabled: true, sslConfiguration: SSLConfiguration(mode: .verifyCa)
            ),
            DatabaseConnection(
                name: "Ledger", type: .oracle, host: "ledger", port: 1_521, username: "scott",
                additionalFields: [
                    OracleConnectionOptions.AdditionalFieldKey.connectionType: "service",
                    OracleConnectionOptions.AdditionalFieldKey.serviceName: "ORCLPDB1"
                ]
            ),
            DatabaseConnection(name: "Local", type: .sqlite, host: "", port: 0, database: "/tmp/local.db"),
            DatabaseConnection(
                name: "Scratch", type: .duckdb, host: "", port: 0, database: LocalDatabaseLocation.inMemoryPath
            ),
            DatabaseConnection(name: "Events", type: .duckdb, host: "", port: 0, database: "/tmp/events.duckdb"),
            DatabaseConnection(
                name: "Tunnelled", type: .mysql, host: "10.0.0.5", port: 3_306, username: "app",
                database: "shop", sshEnabled: true,
                sshConfiguration: SSHConfiguration(
                    host: "bastion", port: 22, username: "deploy", authMethod: .privateKey
                )
            )
        ]
    }

    @Test("A form that has not been touched has no changes")
    func untouchedFormsAreClean() {
        #expect(form().hasChanges == false)
        for connection in existingConnections() {
            #expect(form(editing: connection).hasChanges == false, "\(connection.name)")
        }
    }

    @Test("Every edited field is a change, and putting it back is not")
    func editsAreChangesUntilRestored() {
        let group = UUID()
        let tag = UUID()
        let edits: [(String, (ConnectionFormViewModel) -> Void, (ConnectionFormViewModel) -> Void)] = [
            ("name", { $0.name = "Renamed" }, { $0.name = "Prod" }),
            ("host", { $0.host = "replica" }, { $0.host = "db.example.com" }),
            ("port", { $0.port = "6432" }, { $0.port = "5432" }),
            ("username", { $0.username = "admin" }, { $0.username = "app" }),
            ("password", { $0.password = "s3cret" }, { $0.password = "" }),
            ("database", { $0.database = "analytics" }, { $0.database = "app" }),
            ("safe mode", { $0.safeModeLevel = .readOnly }, { $0.safeModeLevel = .off }),
            ("group", { $0.groupId = group }, { $0.groupId = nil }),
            ("tag", { $0.tagId = tag }, { $0.tagId = nil }),
            ("SSL mode", { $0.sslMode = .require }, { $0.sslMode = .verifyFull }),
            ("SSH", { $0.sshEnabled = true }, { $0.sshEnabled = false })
        ]

        for (label, change, restore) in edits {
            let viewModel = form(editing: postgres())
            change(viewModel)
            #expect(viewModel.hasChanges, "\(label)")
            restore(viewModel)
            #expect(viewModel.hasChanges == false, "\(label)")
        }
    }

    @Test("Every SSH field is a change while the tunnel is on")
    func sshFieldsAreChanges() throws {
        let tunnelled = try #require(existingConnections().first { $0.sshEnabled })
        let edits: [(String, (ConnectionFormViewModel) -> Void)] = [
            ("host", { $0.sshHost = "jump" }),
            ("port", { $0.sshPort = "2222" }),
            ("user", { $0.sshUsername = "ops" }),
            ("password", { $0.sshPassword = "tunnel" }),
            ("key path", { $0.sshKeyPath = "/keys/id_ed25519" }),
            ("key text", { $0.sshKeyContent = "-----BEGIN RSA PRIVATE KEY-----" }),
            ("passphrase", { $0.sshKeyPassphrase = "unlock" })
        ]

        for (label, change) in edits {
            let viewModel = form(editing: tunnelled)
            #expect(viewModel.hasChanges == false, "\(label)")
            change(viewModel)
            #expect(viewModel.hasChanges, "\(label)")
        }
    }

    @Test("Changing the Oracle service name is a change")
    func oracleServiceNameIsAChange() throws {
        let oracle = try #require(existingConnections().first { $0.type == .oracle })
        let viewModel = form(editing: oracle)

        viewModel.oracleServiceName = "ORCLPDB2"
        #expect(viewModel.hasChanges)
        viewModel.oracleServiceName = "ORCLPDB1"
        #expect(viewModel.hasChanges == false)
    }

    @Test("Loading the stored secrets is not a change, and editing one is")
    func loadedSecretsAreClean() async {
        let connection = postgres()
        let viewModel = form(editing: connection)

        await viewModel.loadStoredCredentials(secureStore: seededStore(for: connection))
        #expect(viewModel.password == "stored")
        #expect(viewModel.hasChanges == false)

        viewModel.password = ""
        #expect(viewModel.hasChanges == false, "an empty field keeps the stored password")

        viewModel.password = "rotated"
        #expect(viewModel.hasChanges)
        #expect(viewModel.changesSecrets)
    }

    @Test("A key an older build left in the Keychain is not a change while the connection does not use it")
    func unusedStoredKeyIsClean() async {
        let unused = [tunnel(authMethod: .password), tunnel(authMethod: .privateKey, enabled: false)]
        for connection in unused {
            let store = seededStore(for: connection)
            store.seed("com.TablePro.sshkeydata.\(connection.id.uuidString)", "LEFTOVER KEY")
            let viewModel = form(editing: connection)

            await viewModel.loadStoredCredentials(secureStore: store)

            #expect(viewModel.hasChanges == false, "SSH on: \(connection.sshEnabled)")
            #expect(viewModel.changesSecrets == false, "SSH on: \(connection.sshEnabled)")
            #expect(viewModel.reconnectsAfterSave == false, "SSH on: \(connection.sshEnabled)")
        }
    }

    @Test("Saving an edit drops a leftover key the connection does not use")
    func saveDropsUnusedStoredKey() async throws {
        let connection = tunnel(authMethod: .password)
        let keyAccount = "com.TablePro.sshkeydata.\(connection.id.uuidString)"
        let store = seededStore(for: connection)
        store.seed(keyAccount, "LEFTOVER KEY")
        let viewModel = form(editing: connection)
        await viewModel.loadStoredCredentials(secureStore: store)

        viewModel.name = "Renamed"
        let appState = makeAppState(holding: connection)
        _ = try #require(await viewModel.save(appState: appState, secureStore: store))

        #expect(try store.retrieve(forKey: keyAccount) == nil)
        #expect(try store.retrieve(forKey: "com.TablePro.sshpassword.\(connection.id.uuidString)") == "tunnel")
    }

    @Test("A save whose Keychain write fails leaves only that secret to discard, and saving again stores it")
    func partialSaveKeepsOnlyTheFailedSecretDirty() async throws {
        let connection = postgres()
        let passwordAccount = "com.TablePro.password.\(connection.id.uuidString)"
        let store = seededStore(for: connection)
        let appState = fixture.makeState(syncEnabled: false, secureStore: store)
        #expect(appState.addConnection(connection))
        let viewModel = form(editing: connection)
        await viewModel.loadStoredCredentials(secureStore: store)
        viewModel.name = "Renamed"
        viewModel.password = "rotated"
        store.failNextStore = true

        #expect(await viewModel.save(appState: appState, secureStore: store) == nil)

        #expect(viewModel.credentialError != nil)
        #expect(appState.connections.first?.name == "Renamed")
        #expect(try store.retrieve(forKey: passwordAccount) == "stored")
        #expect(viewModel.hasChanges)
        #expect(viewModel.changesSecrets)

        viewModel.password = ""
        #expect(viewModel.hasChanges == false)

        viewModel.password = "rotated"
        let retriedId = try #require(await viewModel.save(appState: appState, secureStore: store))
        #expect(retriedId == connection.id)
        #expect(try store.retrieve(forKey: passwordAccount) == "rotated")
        #expect(viewModel.hasChanges == false)
        #expect(appState.connections.first?.name == "Renamed")
    }

    @Test("A secret that saved is not offered for discard when a later one fails")
    func savedSecretIsCleanAfterLaterFailure() async throws {
        let connection = tunnel(authMethod: .password)
        let tunnelStore = seededStore(for: connection)
        let appState = makeAppState(holding: connection)
        let viewModel = form(editing: connection)
        await viewModel.loadStoredCredentials(secureStore: tunnelStore)
        viewModel.password = "rotated"
        viewModel.sshPassword = "rotated-tunnel"
        tunnelStore.failNextStore = true

        #expect(await viewModel.save(appState: appState, secureStore: tunnelStore) == nil)

        #expect(try appState.secureStore.retrieve(forKey: "com.TablePro.password.\(connection.id.uuidString)") == "rotated")
        #expect(viewModel.hasChanges)

        viewModel.sshPassword = ""
        #expect(viewModel.hasChanges == false)
    }

    @Test("A certificate the store refuses stays a change once the rest is saved")
    func refusedCertificateStaysStaged() async {
        let connection = postgres()
        let appState = makeAppState(holding: connection)
        let viewModel = form(editing: connection)
        viewModel.name = "Renamed"
        viewModel.pastedCertificate = PEMDocument.encode(Data([1, 2, 3]), as: .certificate)
        viewModel.importPastedCertificate(role: .certificateAuthority)
        certificates.refusesStores = true

        #expect(await viewModel.save(appState: appState, secureStore: MockSecureStore()) == nil)

        #expect(viewModel.credentialError != nil)
        #expect(viewModel.changesSecrets)

        viewModel.removeCertificate(.certificateAuthority)
        #expect(viewModel.hasChanges == false)
    }

    @Test("Switching a new form to another engine and back is not a change")
    func typeRoundTripIsClean() {
        let viewModel = form()
        viewModel.type = .postgresql
        #expect(viewModel.hasChanges)
        viewModel.type = .mysql
        #expect(viewModel.hasChanges == false)
    }

    @Test("SSH typed into and then turned off is not a change, since Save would store none of it")
    func discardedTunnelIsClean() {
        let viewModel = form()
        viewModel.sshEnabled = true
        viewModel.sshHost = "bastion"
        viewModel.sshPassword = "tunnel"
        viewModel.sshKeyPassphrase = "unlock"
        #expect(viewModel.hasChanges)

        viewModel.sshEnabled = false
        #expect(viewModel.hasChanges == false)
    }

    @Test("A staged certificate is a change, and removing it before Save is not")
    func stagedCertificateIsAChange() {
        let viewModel = form(editing: postgres())
        viewModel.pastedCertificate = PEMDocument.encode(Data([1, 2, 3]), as: .certificate)

        viewModel.importPastedCertificate(role: .certificateAuthority)
        #expect(viewModel.hasChanges)
        #expect(viewModel.changesSecrets)

        viewModel.removeCertificate(.certificateAuthority)
        #expect(viewModel.hasChanges == false)
    }

    @Test("A stored certificate is clean once loaded and a change once removed")
    func storedCertificateRemovalIsAChange() throws {
        let connection = postgres()
        try certificates.store(
            PEMDocument.encode(Data([1, 2, 3]), as: .certificate),
            role: .certificateAuthority,
            for: connection.id
        )
        let viewModel = form(editing: connection)

        viewModel.loadCertificateSummaries()
        #expect(viewModel.hasChanges == false)

        viewModel.removeCertificate(.certificateAuthority)
        #expect(viewModel.hasChanges)
        #expect(viewModel.changesSecrets)
    }

    @Test("Saving a rename writes no secret back, so secrets changed on another device survive")
    func renameLeavesChangedSecretsAlone() async throws {
        let tunnelled = try #require(existingConnections().first { $0.sshEnabled })
        let suffix = tunnelled.id.uuidString
        let store = seededStore(for: tunnelled)
        let viewModel = form(editing: tunnelled)
        await viewModel.loadStoredCredentials(secureStore: store)

        store.seed("com.TablePro.sshpassword.\(suffix)", "rotated-tunnel")
        store.seed("com.TablePro.keypassphrase.\(suffix)", "rotated-unlock")
        viewModel.name = "Renamed"

        #expect(viewModel.secretWrites == ConnectionFormSecretWrites())
        #expect(viewModel.reconnectsAfterSave == false)
        let appState = makeAppState(holding: tunnelled)
        _ = try #require(await viewModel.save(appState: appState, secureStore: store))

        #expect(try store.retrieve(forKey: "com.TablePro.sshpassword.\(suffix)") == "rotated-tunnel")
        #expect(try store.retrieve(forKey: "com.TablePro.keypassphrase.\(suffix)") == "rotated-unlock")
        #expect(try store.retrieve(forKey: "com.TablePro.sshkeydata.\(suffix)") == nil)
    }

    @Test("Only the secrets edited in the form are written")
    func editedSecretsAreWritten() async throws {
        let tunnelled = try #require(existingConnections().first { $0.sshEnabled })
        let suffix = tunnelled.id.uuidString
        let store = seededStore(for: tunnelled)
        let viewModel = form(editing: tunnelled)
        await viewModel.loadStoredCredentials(secureStore: store)

        viewModel.sshKeyPassphrase = "new-unlock"
        viewModel.sshKeyContent = "-----BEGIN RSA PRIVATE KEY-----"

        #expect(viewModel.secretWrites == ConnectionFormSecretWrites(sshKeyPassphrase: "new-unlock"))
        #expect(viewModel.pastedPrivateKey == "-----BEGIN RSA PRIVATE KEY-----")
        #expect(viewModel.reconnectsAfterSave)
        let appState = makeAppState(holding: tunnelled)
        _ = try #require(await viewModel.save(appState: appState, secureStore: store))

        #expect(try store.retrieve(forKey: "com.TablePro.sshpassword.\(suffix)") == "tunnel")
        #expect(try store.retrieve(forKey: "com.TablePro.keypassphrase.\(suffix)") == "new-unlock")
        #expect(try store.retrieve(forKey: "com.TablePro.sshkeydata.\(suffix)") == "-----BEGIN RSA PRIVATE KEY-----")
    }

    @Test("A changed password is written, and one typed back to the stored value is not")
    func passwordWriteFollowsTheLoadedValue() async {
        let connection = postgres()
        let viewModel = form(editing: connection)
        await viewModel.loadStoredCredentials(secureStore: seededStore(for: connection))

        viewModel.password = "rotated"
        #expect(viewModel.secretWrites == ConnectionFormSecretWrites(password: "rotated"))

        viewModel.password = "stored"
        #expect(viewModel.secretWrites == ConnectionFormSecretWrites())
    }

    @Test("A new connection writes every secret typed into it, and SSH secrets only with SSH on")
    func newConnectionWritesTypedSecrets() {
        let viewModel = form()
        viewModel.password = "secret"
        viewModel.sshEnabled = true
        viewModel.sshPassword = "tunnel"

        #expect(viewModel.secretWrites == ConnectionFormSecretWrites(password: "secret", sshPassword: "tunnel"))

        viewModel.sshEnabled = false
        #expect(viewModel.secretWrites == ConnectionFormSecretWrites(password: "secret"))
    }

    @Test("A rename saved over a newer record keeps what changed elsewhere")
    func editAppliesOnlyChangedFields() {
        let stored = postgres()
        let viewModel = form(editing: stored)
        viewModel.name = "Renamed"

        var synced = stored
        synced.safeModeLevel = .readOnly
        synced.isReadOnly = true
        synced.isFavorite = true
        synced.sortOrder = 9
        let merged = viewModel.applyingEdits(to: synced)

        #expect(merged.name == "Renamed")
        #expect(merged.safeModeLevel == .readOnly)
        #expect(merged.isReadOnly)
        #expect(merged.isFavorite)
        #expect(merged.sortOrder == 9)
        #expect(merged.dialsTheSameWay(as: synced))
    }

    @Test("Only an edit of a saved connection that changes a secret reconnects its open screen")
    func reconnectFollowsSecretChanges() async {
        let connection = postgres()
        let renamed = form(editing: connection)
        await renamed.loadStoredCredentials(secureStore: seededStore(for: connection))
        renamed.name = "Renamed"
        #expect(renamed.hasChanges)
        #expect(renamed.reconnectsAfterSave == false)

        let rotated = form(editing: connection)
        await rotated.loadStoredCredentials(secureStore: seededStore(for: connection))
        rotated.password = "rotated"
        #expect(rotated.reconnectsAfterSave)

        let created = form()
        created.password = "secret"
        #expect(created.changesSecrets)
        #expect(created.reconnectsAfterSave == false)
    }
}
