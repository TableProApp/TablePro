import Foundation
import TableProDatabase
import TableProModels
import Testing

@testable import TableProMobile

enum PastedKeyAbandonment: CaseIterable, Sendable {
    case passwordAuth
    case tunnelOff
    case importFile
}

@MainActor
@Suite("Connection form SSH private key")
struct ConnectionFormViewModelSSHKeyTests {
    private let keyMarker = "b3BlbnNzaC1rZXktdjEAAAAABG5vbmU"

    private var pastedKey: String {
        "-----BEGIN OPENSSH PRIVATE KEY-----\n\(keyMarker)\n-----END OPENSSH PRIVATE KEY-----\n"
    }

    private func makeTunnelledConnection(keyPath: String? = nil) -> DatabaseConnection {
        DatabaseConnection(
            name: "Bastion",
            type: .postgresql,
            host: "10.0.0.5",
            port: 5_432,
            sshEnabled: true,
            sshConfiguration: SSHConfiguration(
                host: "bastion.example.com",
                username: "deploy",
                authMethod: .privateKey,
                privateKeyPath: keyPath
            )
        )
    }

    private func keyAccount(_ id: UUID) -> String {
        "com.TablePro.sshkeydata.\(id.uuidString)"
    }

    private func loadedForm(_ connection: DatabaseConnection, store: MockSecureStore) async -> ConnectionFormViewModel {
        let form = ConnectionFormViewModel(editing: connection)
        await form.loadStoredCredentials(secureStore: store)
        return form
    }

    private func makeAppState() throws -> AppState {
        try AppStateFixture().makeState(syncEnabled: false)
    }

    @Test("A new connection keeps one id for as long as its form is open")
    func newConnectionIdIsStable() {
        let form = ConnectionFormViewModel()
        let first = form.buildConnection()
        let second = form.buildConnection()

        #expect(first.id == form.connectionId)
        #expect(second.id == form.connectionId)

        let existing = makeTunnelledConnection()
        #expect(ConnectionFormViewModel(editing: existing).connectionId == existing.id)
    }

    @Test("A Save retried after a refused credential write keeps the key under the id it saves")
    func retriedSaveKeepsKeyWithConnection() async throws {
        let appState = try makeAppState()
        let store = MockSecureStore()
        let form = ConnectionFormViewModel()
        form.host = "10.0.0.5"
        form.sshEnabled = true
        form.sshHost = "bastion.example.com"
        form.sshAuthMethod = .privateKey
        form.sshKeyInputMode = .paste
        form.sshKeyContent = pastedKey
        form.sshKeyPassphrase = "phrase"
        store.failNextStore = true

        #expect(await form.save(appState: appState, secureStore: store) == nil)
        #expect(form.credentialError != nil)

        let savedId = try #require(await form.save(appState: appState, secureStore: store))

        #expect(savedId == form.connectionId)
        #expect(try store.retrieve(forKey: keyAccount(savedId)) == pastedKey)
        #expect(try store.retrieve(forKey: "com.TablePro.keypassphrase.\(savedId.uuidString)") == "phrase")
    }

    @Test("A pasted key never reaches the connection that is written to the file")
    func buildConnectionOmitsPastedKey() throws {
        let form = ConnectionFormViewModel()
        form.host = "10.0.0.5"
        form.sshEnabled = true
        form.sshHost = "bastion.example.com"
        form.sshAuthMethod = .privateKey
        form.sshKeyInputMode = .paste
        form.sshKeyContent = pastedKey

        let encoded = try JSONEncoder().encode([form.buildConnection()])
        let text = try #require(String(data: encoded, encoding: .utf8))

        #expect(!text.contains(keyMarker))
        #expect(!text.contains("privateKeyData"))
        #expect(form.pastedPrivateKey == pastedKey)
    }

    @Test("Saving a pasted key stores it in the secure store under the connection id")
    func persistStoresPastedKey() throws {
        let store = MockSecureStore()
        let form = ConnectionFormViewModel()
        form.sshEnabled = true
        form.sshAuthMethod = .privateKey
        form.sshKeyInputMode = .paste
        form.sshKeyContent = pastedKey

        try form.persistPrivateKey(secureStore: store)

        #expect(try store.retrieve(forKey: keyAccount(form.buildConnection().id)) == pastedKey)
    }

    @Test("Editing a connection loads its stored key and selects Paste Key")
    func loadSelectsPasteKey() async throws {
        let connection = makeTunnelledConnection(keyPath: "/keys/id_ed25519")
        let store = MockSecureStore()
        store.seed(keyAccount(connection.id), pastedKey)

        let form = ConnectionFormViewModel(editing: connection)
        #expect(form.sshKeyInputMode == .file)

        await form.loadStoredCredentials(secureStore: store)

        #expect(form.sshKeyContent == pastedKey)
        #expect(form.sshKeyInputMode == .paste)
        #expect(form.pastedPrivateKey == pastedKey)
    }

    @Test("A private key connection with no key file opens on Paste Key, one with a file on Import File")
    func initialInputMode() {
        #expect(ConnectionFormViewModel(editing: makeTunnelledConnection()).sshKeyInputMode == .paste)
        #expect(
            ConnectionFormViewModel(editing: makeTunnelledConnection(keyPath: "/keys/id_rsa")).sshKeyInputMode == .file
        )
    }

    @Test("Leaving the pasted key behind deletes it on save", arguments: PastedKeyAbandonment.allCases)
    func switchingAwayDeletesKey(_ change: PastedKeyAbandonment) async throws {
        let connection = makeTunnelledConnection()
        let store = MockSecureStore()
        store.seed(keyAccount(connection.id), pastedKey)
        let form = await loadedForm(connection, store: store)

        switch change {
        case .passwordAuth: form.sshAuthMethod = .password
        case .tunnelOff: form.sshEnabled = false
        case .importFile: form.sshKeyInputMode = .file
        }
        try form.persistPrivateKey(secureStore: store)

        #expect(try store.retrieve(forKey: keyAccount(connection.id)) == nil)
    }

    @Test("Saving before the stored key has loaded leaves it alone")
    func saveBeforeLoadKeepsKey() throws {
        let connection = makeTunnelledConnection()
        let store = MockSecureStore()
        store.seed(keyAccount(connection.id), pastedKey)
        let form = ConnectionFormViewModel(editing: connection)

        try form.persistPrivateKey(secureStore: store)

        #expect(try store.retrieve(forKey: keyAccount(connection.id)) == pastedKey)
    }

    @Test("Saving an unchanged key writes nothing")
    func unchangedKeyIsNotRewritten() async throws {
        let connection = makeTunnelledConnection()
        let store = MockSecureStore()
        store.seed(keyAccount(connection.id), pastedKey)
        let form = await loadedForm(connection, store: store)
        store.failNextStore = true

        try form.persistPrivateKey(secureStore: store)

        #expect(store.failNextStore)
        #expect(try store.retrieve(forKey: keyAccount(connection.id)) == pastedKey)
    }

    @Test("A refused key write is reported")
    func refusedStoreThrows() {
        let store = MockSecureStore()
        store.failNextStore = true
        let form = ConnectionFormViewModel()
        form.sshEnabled = true
        form.sshAuthMethod = .privateKey
        form.sshKeyInputMode = .paste
        form.sshKeyContent = pastedKey

        #expect(throws: (any Error).self) {
            try form.persistPrivateKey(secureStore: store)
        }
    }

    @Test("A picked key file that is not text is copied beside another connection's key of the same name")
    func pickedKeyFileNeverOverwritesAnother() throws {
        let fixture = try AppStateFixture()
        let firstKey = Data([0xFF, 0xFE, 0x00, 0x81, 0x01])
        let secondKey = Data([0xFF, 0xFE, 0x00, 0x81, 0x02])
        let firstPick = try pickedFile(named: "id_key", in: "Laptop", contents: firstKey, fixture: fixture)
        let secondPick = try pickedFile(named: "id_key", in: "Server", contents: secondKey, fixture: fixture)
        let first = fixture.makeFormViewModel()
        let second = fixture.makeFormViewModel()

        first.handleSSHKeyFilePicker(.success([firstPick]))
        second.handleSSHKeyFilePicker(.success([secondPick]))

        #expect(first.sshKeyFileError == nil)
        #expect(second.sshKeyFileError == nil)
        #expect(first.sshKeyPath != second.sshKeyPath)
        #expect(fixture.localFiles.isInDocuments(URL(fileURLWithPath: first.sshKeyPath)))
        #expect(fixture.localFiles.isInDocuments(URL(fileURLWithPath: second.sshKeyPath)))
        #expect(try Data(contentsOf: URL(fileURLWithPath: first.sshKeyPath)) == firstKey)
        #expect(try Data(contentsOf: URL(fileURLWithPath: second.sshKeyPath)) == secondKey)
    }

    private func pickedFile(named name: String, in folder: String, contents: Data, fixture: AppStateFixture) throws -> URL {
        let directory = fixture.root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    @Test("A key file that cannot be copied records no path and says why")
    func failedKeyCopyRecordsNoPath() throws {
        let fixture = try AppStateFixture()
        let form = fixture.makeFormViewModel()
        let missing = fixture.root.appendingPathComponent("Picked/gone_key")

        form.handleSSHKeyFilePicker(.success([missing]))

        #expect(form.sshKeyPath.isEmpty)
        #expect(form.sshKeyFileError != nil)
    }

    @Test("A key file picked from the app's own documents is used where it is")
    func documentsKeyFileIsUsedInPlace() throws {
        let fixture = try AppStateFixture()
        let form = fixture.makeFormViewModel()
        let inDocuments = fixture.documentsFile("deploy_key")
        try Data([0xFF, 0xFE, 0x01]).write(to: inDocuments)

        form.handleSSHKeyFilePicker(.success([inDocuments]))

        #expect(form.sshKeyPath == inDocuments.path)
        #expect(form.sshKeyFileError == nil)
    }

    @Test("A picked text key becomes a pasted key and no file is copied")
    func pickedTextKeyIsPasted() throws {
        let fixture = try AppStateFixture()
        let form = fixture.makeFormViewModel()
        let picked = fixture.root.appendingPathComponent("id_ed25519")
        try Data(pastedKey.utf8).write(to: picked)

        form.handleSSHKeyFilePicker(.success([picked]))

        #expect(form.sshKeyContent == pastedKey)
        #expect(form.sshKeyInputMode == .paste)
        #expect(form.sshKeyPath.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.documentsDirectory.path).isEmpty)
    }

    @Test("Test Connection hands the tunnel the form's secrets under the throwaway id only")
    func testSecretsCarryFormValues() {
        let form = ConnectionFormViewModel()
        form.password = "db-secret"
        form.sshEnabled = true
        form.sshAuthMethod = .privateKey
        form.sshKeyInputMode = .paste
        form.sshKeyContent = pastedKey
        form.sshKeyPassphrase = "phrase"
        let tempId = UUID()

        let credentials = SSHTunnelCredentials(
            connectionId: tempId,
            secureStore: EphemeralSecureStore(form.testSecrets(for: tempId))
        )

        #expect(form.testSecrets(for: tempId)["com.TablePro.password.\(tempId.uuidString)"] == "db-secret")
        #expect(credentials.privateKeySource(keyPath: nil) == .inMemory(pastedKey))
        #expect(credentials.keyPassphrase == "phrase")
        #expect(form.testSecrets(for: tempId).keys.allSatisfy { $0.hasSuffix(tempId.uuidString) })
    }

    @Test("Test Connection leaves out SSH secrets when the tunnel is off and the key in Import File mode")
    func testSecretsFollowTheForm() {
        let form = ConnectionFormViewModel()
        form.sshEnabled = true
        form.sshAuthMethod = .privateKey
        form.sshKeyInputMode = .file
        form.sshKeyContent = pastedKey
        form.sshPassword = "ssh-secret"
        let tempId = UUID()

        #expect(form.testSecrets(for: tempId)[keyAccount(tempId)] == nil)

        form.sshEnabled = false
        #expect(form.testSecrets(for: tempId).isEmpty)
    }
}
