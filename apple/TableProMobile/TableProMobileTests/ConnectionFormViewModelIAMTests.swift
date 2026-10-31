import Foundation
import TableProDatabase
import TableProModels
import Testing

@testable import TableProMobile

@MainActor
struct ConnectionFormViewModelIAMTests {
    private static let rdsHost = "mydb.abc123.us-east-1.rds.amazonaws.com"
    private static let serviceAccountJSON = #"""
        {"type":"service_account","client_email":"reader@proj.iam.gserviceaccount.com","private_key":"-----BEGIN PRIVATE KEY-----\nMIIB\n-----END PRIVATE KEY-----\n"}
        """#

    private let fixture: AppStateFixture

    init() throws {
        fixture = try AppStateFixture()
    }

    private func rds(_ method: IAMSignIn, fields: [String: String] = [:]) -> DatabaseConnection {
        DatabaseConnection(
            name: "Orders",
            type: .postgresql,
            host: Self.rdsHost,
            port: 5_432,
            username: "iam_user",
            database: "orders",
            additionalFields: ["awsAuth": method.pickerValue, "awsRegion": "us-east-1"]
                .merging(fields) { _, new in new }
        )
    }

    private func loadedForm(_ connection: DatabaseConnection, store: MockSecureStore) async -> ConnectionFormViewModel {
        let form = fixture.makeFormViewModel(editing: connection)
        await form.loadStoredCredentials(secureStore: store)
        return form
    }

    private func makeAppState(holding connection: DatabaseConnection, store: MockSecureStore) -> AppState {
        let state = fixture.makeState(syncEnabled: false, secureStore: store)
        #expect(state.addConnection(connection))
        return state
    }

    @Test("A MongoDB edit tests with the session token and key passphrase the Mac keeps, under the test's own id")
    func mongoKeychainSecretsReachTheTest() async {
        let connection = DatabaseConnection(
            name: "Docs",
            type: .mongodb,
            host: "db.example.com",
            port: 27_017,
            username: "AKIAEXAMPLE",
            database: "app",
            additionalFields: ["mongoAuthMechanism": "MONGODB-AWS"]
        )
        let store = MockSecureStore()
        store.seed(ConnectionSecretKind.mongoAWSSessionToken.account(for: connection.id), "FQoGSESSION")
        store.seed(ConnectionSecretKind.sslKeyPassphrase.account(for: connection.id), "hunter2")
        let form = await loadedForm(connection, store: store)

        let tempId = UUID()
        let secrets = form.testSecrets(for: tempId)

        #expect(secrets[ConnectionSecretKind.mongoAWSSessionToken.account(for: tempId)] == "FQoGSESSION")
        #expect(secrets[ConnectionSecretKind.sslKeyPassphrase.account(for: tempId)] == "hunter2")
    }

    @Test("An edit with no change tests with the access key it loaded, under the test's own id")
    func unchangedEditTestsWithLoadedAccessKey() async throws {
        let connection = rds(.awsAccessKey, fields: ["awsAccessKeyId": "AKIAEXAMPLE"])
        let store = MockSecureStore()
        store.seed(ConnectionSecretKind.awsSecretAccessKey.account(for: connection.id), "wJalrSECRET")
        store.seed(ConnectionSecretKind.awsSessionToken.account(for: connection.id), "FQoGSESSION")
        let form = await loadedForm(connection, store: store)
        #expect(form.hasChanges == false)

        let tempId = UUID()
        let secrets = EphemeralSecureStore(form.testSecrets(for: tempId))
        #expect(try secrets.retrieve(forKey: ConnectionSecretKind.awsSecretAccessKey.account(for: tempId)) == "wJalrSECRET")
        #expect(try secrets.retrieve(forKey: ConnectionSecretKind.awsSessionToken.account(for: tempId)) == "FQoGSESSION")

        var testConnection = form.buildConnection()
        testConnection.id = tempId
        let token = try await IAMPasswordMint().password(for: testConnection, method: .awsAccessKey, secureStore: secrets)
        #expect(token.hasPrefix("\(Self.rdsHost):5432/?Action=connect&DBUser=iam_user&"))
        #expect(token.contains("X-Amz-Security-Token=FQoGSESSION"))
    }

    @Test("The device's Identity Center settings reach Test Connection under its own id")
    func deviceItemFollowsTheTest() async throws {
        let connection = rds(.awsSSO, fields: ["awsProfileName": "prod"])
        let store = MockSecureStore()
        let device = DeviceIAMCredentials(
            ssoStartUrl: "https://example.awsapps.com/start",
            ssoRegion: "us-east-1",
            ssoAccountId: "111122223333",
            ssoRoleName: "ReadOnly"
        )
        try device.save(for: connection.id, to: store)
        let form = await loadedForm(connection, store: store)
        #expect(form.hasChanges == false)

        let tempId = UUID()
        let secrets = EphemeralSecureStore(form.testSecrets(for: tempId))

        #expect(try DeviceIAMCredentials.load(for: tempId, from: secrets) == device)
        #expect(try secrets.retrieve(forKey: DeviceIAMCredentials.account(for: connection.id)) == nil)
    }

    @Test("A synced service account key reads Saved and reaches Test Connection under its own id")
    func serviceAccountKeyFollowsTheTest() async {
        let connection = rds(.googleServiceAccount)
        let store = MockSecureStore()
        store.seed(ConnectionSecretKind.gcpServiceAccountKey.account(for: connection.id), Self.serviceAccountJSON)
        let form = await loadedForm(connection, store: store)

        #expect(form.serviceAccountKeyStatus == String(localized: "Saved"))
        let tempId = UUID()
        let secrets = form.testSecrets(for: tempId)
        #expect(secrets[ConnectionSecretKind.gcpServiceAccountKey.account(for: tempId)] == Self.serviceAccountJSON)
    }

    @Test("A service account key that is a path on the Mac says so")
    func macPathKeyIsNamed() async {
        let connection = rds(.googleServiceAccount)
        let store = MockSecureStore()
        store.seed(ConnectionSecretKind.gcpServiceAccountKey.account(for: connection.id), "~/keys/reader.json")
        let form = await loadedForm(connection, store: store)

        #expect(form.serviceAccountKeyStatus == String(localized: "File on the Mac"))
    }

    @Test("Loading the IAM secrets is not a change, and editing one is")
    func loadedIAMSecretsAreClean() async {
        let connection = rds(.awsAccessKey, fields: ["awsAccessKeyId": "AKIAEXAMPLE"])
        let store = MockSecureStore()
        store.seed(ConnectionSecretKind.awsSecretAccessKey.account(for: connection.id), "wJalrSECRET")
        let form = await loadedForm(connection, store: store)

        #expect(form.iam.secrets.secretAccessKey == "wJalrSECRET")
        #expect(form.hasChanges == false)
        #expect(form.reconnectsAfterSave == false)

        form.iam.secrets.secretAccessKey = ""
        #expect(form.hasChanges == false, "an empty field keeps the stored key")

        form.iam.secrets.secretAccessKey = "rotated"
        #expect(form.reconnectsAfterSave)
        #expect(form.secretWrites == ConnectionFormSecretWrites(iam: ConnectionIAMSecretWrites(secretAccessKey: "rotated")))
    }

    @Test("Clearing the session token deletes it, and the secret access key stays")
    func clearedSessionTokenIsDeleted() async throws {
        let connection = rds(.awsAccessKey, fields: ["awsAccessKeyId": "AKIAEXAMPLE"])
        let store = MockSecureStore()
        let secretAccount = ConnectionSecretKind.awsSecretAccessKey.account(for: connection.id)
        let tokenAccount = ConnectionSecretKind.awsSessionToken.account(for: connection.id)
        store.seed(secretAccount, "wJalrSECRET")
        store.seed(tokenAccount, "FQoGSESSION")
        let form = await loadedForm(connection, store: store)

        form.iam.secrets.sessionToken = ""
        let appState = makeAppState(holding: connection, store: store)
        _ = try #require(await form.save(appState: appState, secureStore: store))

        #expect(try store.retrieve(forKey: tokenAccount) == nil)
        #expect(try store.retrieve(forKey: secretAccount) == "wJalrSECRET")
        #expect(form.hasChanges == false)
    }

    @Test("Saving a rename writes no IAM secret back, so a key changed on the Mac survives")
    func renameLeavesIAMSecretsAlone() async throws {
        let connection = rds(.awsAccessKey, fields: ["awsAccessKeyId": "AKIAEXAMPLE"])
        let store = MockSecureStore()
        let secretAccount = ConnectionSecretKind.awsSecretAccessKey.account(for: connection.id)
        store.seed(secretAccount, "wJalrSECRET")
        let form = await loadedForm(connection, store: store)

        store.seed(secretAccount, "rotated-on-mac")
        form.name = "Renamed"
        #expect(form.secretWrites == ConnectionFormSecretWrites())
        let appState = makeAppState(holding: connection, store: store)
        _ = try #require(await form.save(appState: appState, secureStore: store))

        #expect(try store.retrieve(forKey: secretAccount) == "rotated-on-mac")
    }

    @Test("A Profile device key is saved in the device item and never in the synced fields")
    func profileDeviceKeyStaysOnTheDevice() async throws {
        let connection = rds(.awsProfile, fields: ["awsProfileName": "prod"])
        let store = MockSecureStore()
        let form = await loadedForm(connection, store: store)
        form.iam.secrets.device.accessKeyId = "AKIADEVICE"
        form.iam.secrets.device.secretAccessKey = "device-secret"
        #expect(form.reconnectsAfterSave)

        let appState = makeAppState(holding: connection, store: store)
        _ = try #require(await form.save(appState: appState, secureStore: store))

        let device = try DeviceIAMCredentials.load(for: connection.id, from: store)
        #expect(device.accessKeyId == "AKIADEVICE")
        #expect(device.secretAccessKey == "device-secret")
        let saved = appState.connections.first { $0.id == connection.id }
        #expect(saved?.additionalFields == connection.additionalFields)
        #expect(form.hasChanges == false)
    }

    @Test("A region edit keeps an RDS Endpoint the Mac changed while the form was open")
    func regionEditKeepsEndpointChangedElsewhere() {
        let connection = rds(.awsAccessKey, fields: ["awsAccessKeyId": "AKIAEXAMPLE"])
        let form = fixture.makeFormViewModel(editing: connection)
        var current = connection
        current.additionalFields["awsRDSEndpoint"] = "proxy.example.com:5432"
        #expect(form.applyingEdits(to: current) == current)

        form.iam.region = "eu-west-1"
        let saved = form.applyingEdits(to: current)

        #expect(saved.additionalFields["awsRegion"] == "eu-west-1")
        #expect(saved.additionalFields["awsRDSEndpoint"] == "proxy.example.com:5432")
        #expect(saved.additionalFields["awsAccessKeyId"] == "AKIAEXAMPLE")
    }

    @Test("A new connection stores no method until one is picked, and turning IAM off writes Password")
    func methodIsWrittenOnlyWhenPicked() {
        let fresh = fixture.makeFormViewModel()
        fresh.type = .postgresql
        #expect(fresh.buildConnection().additionalFields.isEmpty)

        fresh.iam.method = .awsAccessKey
        fresh.iam.accessKeyId = "AKIAEXAMPLE"
        #expect(fresh.signsInWithIAM)
        #expect(fresh.buildConnection().additionalFields == ["awsAuth": "accessKey", "awsAccessKeyId": "AKIAEXAMPLE"])

        let connection = rds(.awsAccessKey)
        let editing = fixture.makeFormViewModel(editing: connection)
        editing.iam.method = nil

        #expect(editing.signsInWithIAM == false)
        #expect(editing.applyingEdits(to: connection).additionalFields["awsAuth"] == "off")
    }

    @Test("An engine that does not offer the method turns it off, and one without IAM has no section")
    func typeChangeDropsUnofferedMethod() {
        let form = fixture.makeFormViewModel()
        form.iam.method = .googleServiceAccount
        form.type = .mariadb
        #expect(form.iam.method == nil)

        form.iam.method = .awsAccessKey
        form.type = .redis
        #expect(form.iam.method == .awsAccessKey)
        #expect(form.iamAWSService == .elastiCache)

        form.type = .mssql
        #expect(form.offersIAM == false)
        #expect(form.iam.method == nil)
        #expect(form.edits.iam == nil)
    }

    @Test("Fields typed under a method that is then turned off are not a change")
    func discardedMethodIsClean() {
        let form = fixture.makeFormViewModel()
        form.iam.method = .awsAccessKey
        form.iam.accessKeyId = "AKIAEXAMPLE"
        form.iam.secrets.secretAccessKey = "secret"
        #expect(form.hasChanges)

        form.iam.method = nil
        #expect(form.hasChanges == false)
        #expect(form.testSecrets(for: UUID()).isEmpty)
    }

    @Test("A pasted key with a byte order mark is taken, while a private key alone or a Mac path is refused")
    func pastedKeyValidation() {
        #expect(ConnectionFormViewModel.serviceAccountKeyProblem("\u{FEFF}\n" + Self.serviceAccountJSON) == nil)
        #expect(ConnectionFormViewModel.serviceAccountKeyProblem("-----BEGIN PRIVATE KEY-----\nMIIB\n-----END PRIVATE KEY-----") != nil)
        #expect(ConnectionFormViewModel.serviceAccountKeyProblem("~/keys/reader.json") != nil)

        let form = fixture.makeFormViewModel()
        form.iam.method = .googleApplicationDefault
        form.adoptServiceAccountKey(Self.serviceAccountJSON)

        #expect(form.iam.secrets.device.serviceAccountKey == Self.serviceAccountJSON)
        #expect(form.iam.secrets.serviceAccountKey.isEmpty)
    }
}
