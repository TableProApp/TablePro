import Foundation
@testable import TablePro
import Testing

@MainActor
struct AuthPanePasswordSourceTests {
    private let suite: EphemeralDefaults

    init() throws {
        suite = try EphemeralDefaults()
    }

    private func makeStorage() -> ConnectionStorage {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("connections.json")
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return ConnectionStorage(fileURL: fileURL, userDefaults: suite.defaults, keychain: InMemoryKeychain())
    }

    private func loadedModel(source: PasswordSource?, configure: (inout DatabaseConnection) -> Void = { _ in }) -> AuthPaneViewModel {
        var connection = TestFixtures.makeConnection()
        connection.username = "app"
        connection.passwordSource = source
        configure(&connection)
        let model = AuthPaneViewModel()
        model.load(from: connection, storage: makeStorage())
        return model
    }

    @Test("The form knows where a connection's password comes from")
    func loadsThePasswordSource() {
        let source = PasswordSource.command(shell: "op read op://vault/db/password")
        let model = loadedModel(source: source)

        #expect(model.passwordSource == source)
        #expect(model.passwordSourceInUse == source)
    }

    @Test("A prompt or a linked profile overrides the connection's own source")
    func promptAndProfileOverrideTheSource() {
        let model = loadedModel(source: .env(variable: "DB_PASSWORD"))

        model.promptForPassword = true
        #expect(model.passwordSourceInUse == nil)

        model.promptForPassword = false
        model.credentialMode = .profile(id: UUID())
        #expect(model.passwordSourceInUse == nil)
    }

    @Test("Saving a source-backed connection as a profile keeps the source")
    func promotionKeepsATrustedSource() {
        let source = PasswordSource.file(path: "~/.secrets/db")
        let model = loadedModel(source: source)

        #expect(model.profileFromCurrentCredentials(sourceStoreIsTrusted: true).passwordMode == .source(source))
    }

    @Test("A source from a connections file something else changed becomes a prompt, never a profile source")
    func promotionDropsAnUntrustedSource() {
        let model = loadedModel(source: .command(shell: "echo owned"))

        #expect(model.profileFromCurrentCredentials(sourceStoreIsTrusted: false).passwordMode == .prompt)
    }

    @Test("Saving a ~/.pgpass connection as a profile keeps ~/.pgpass")
    func promotionKeepsPgpass() {
        let model = loadedModel(source: nil)
        model.additionalFieldValues["usePgpass"] = "true"

        #expect(model.profileFromCurrentCredentials(sourceStoreIsTrusted: true).passwordMode == .pgpass)
    }

    @Test("Test Connection asks for the password when Prompt for password is on")
    func testConnectionCarriesThePromptFlag() {
        let coordinator = ConnectionFormCoordinator(connectionId: nil)
        coordinator.auth.promptForPassword = true

        let connection = coordinator.connectionForTest()

        #expect(connection.promptForPassword)
        #expect(ConnectionCredentialResolver.promptsForPassword(connection))
    }

    @Test("Test Connection runs the connection's source, not a Keychain password left beside it")
    func testConnectionUsesTheSource() {
        let source = PasswordSource.env(variable: "DB_PASSWORD")
        var connection = TestFixtures.makeConnection()
        connection.passwordSource = source
        let storage = makeStorage()
        #expect(storage.savePassword("stale", for: connection.id))
        let coordinator = ConnectionFormCoordinator(connectionId: nil)
        coordinator.auth.load(from: connection, storage: storage)

        #expect(coordinator.auth.password == "stale")
        #expect(coordinator.connectionForTest().passwordSource == source)
    }

    @Test("A connection with only a source can still be saved as a profile")
    func sourceAloneIsPromotable() {
        let model = loadedModel(source: .env(variable: "REDIS_PASSWORD")) { connection in
            connection.username = ""
        }

        #expect(model.hasPromotableCredentials)
    }
}
