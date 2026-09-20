import Foundation
import TableProImport
@testable import TableProMobile
import TableProModels
import Testing

@MainActor
@Suite("iOS connection export")
struct IOSConnectionExportServiceTests {
    private let fixture: AppStateFixture
    private let keyMarker = "b3BlbnNzaC1rZXktdjEAAAAABG5vbmU"

    init() throws {
        fixture = try AppStateFixture()
    }

    private func makeState(secureStore: MockSecureStore) -> AppState {
        fixture.makeState(syncEnabled: false, secureStore: secureStore)
    }

    private func exportedText(includeCredentials: Bool) async throws -> String {
        let store = MockSecureStore()
        let state = makeState(secureStore: store)
        let connection = DatabaseConnection(
            name: "Bastion",
            type: .postgresql,
            host: "10.0.0.5",
            sshEnabled: true,
            sshConfiguration: SSHConfiguration(host: "bastion.example.com", username: "deploy", authMethod: .privateKey)
        )
        #expect(state.addConnection(connection))
        store.seed("com.TablePro.password.\(connection.id.uuidString)", "db-secret")
        store.seed(
            "com.TablePro.sshkeydata.\(connection.id.uuidString)",
            "-----BEGIN OPENSSH PRIVATE KEY-----\n\(keyMarker)\n-----END OPENSSH PRIVATE KEY-----"
        )

        let passphrase = includeCredentials ? "export-passphrase" : nil
        let data = try await IOSConnectionExportService.exportData(
            connections: state.connections,
            appState: state,
            includeCredentials: includeCredentials,
            passphrase: passphrase
        )
        guard let passphrase else {
            return try #require(String(data: data, encoding: .utf8))
        }
        #expect(ConnectionExportCrypto.isEncrypted(data))
        let decrypted = try await ConnectionExportCrypto.decrypt(data: data, passphrase: passphrase)
        return try #require(String(data: decrypted, encoding: .utf8))
    }

    @Test("An export without credentials never carries a stored private key")
    func plainExportOmitsKey() async throws {
        let text = try await exportedText(includeCredentials: false)
        #expect(text.contains("bastion.example.com"))
        #expect(!text.contains(keyMarker))
        #expect(!text.contains("db-secret"))
    }

    @Test("An export with credentials carries the password but never the private key")
    func credentialExportOmitsKey() async throws {
        let text = try await exportedText(includeCredentials: true)
        #expect(text.contains("db-secret"))
        #expect(!text.contains(keyMarker))
    }

    @Test("An exported jump host keeps the auth method and key path it was synced with")
    func exportKeepsJumpHostCredentials() async throws {
        let state = makeState(secureStore: MockSecureStore())
        let connection = DatabaseConnection(
            name: "Bastion",
            type: .postgresql,
            host: "10.0.0.5",
            sshEnabled: true,
            sshConfiguration: SSHConfiguration(
                host: "db-1",
                username: "deploy",
                jumpHosts: [
                    SSHJumpHost(
                        host: "bastion-1",
                        username: "ops",
                        macAuthMethod: "Private Key",
                        macPrivateKeyPath: "~/.ssh/id_ed25519"
                    )
                ]
            )
        )
        #expect(state.addConnection(connection))

        let data = try await IOSConnectionExportService.exportData(
            connections: state.connections,
            appState: state,
            includeCredentials: false,
            passphrase: nil
        )
        let envelope = try ConnectionImportDecoder.decodeData(data)
        let hop = try #require(envelope.connections.first?.sshConfig?.jumpHosts?.first)

        #expect(hop.host == "bastion-1")
        #expect(hop.port == nil)
        #expect(hop.authMethod == "Private Key")
        #expect(hop.privateKeyPath == "~/.ssh/id_ed25519")
    }
}
