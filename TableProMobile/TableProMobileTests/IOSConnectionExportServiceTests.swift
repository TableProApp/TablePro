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

    private func makeState(secureStore: MockSecureStore = MockSecureStore()) -> AppState {
        fixture.makeState(syncEnabled: false, secureStore: secureStore)
    }

    private func exportedBundle(_ connections: [DatabaseConnection], from state: AppState) async throws -> ConnectionBundle {
        let data = try await IOSConnectionExportService.exportData(
            connections: connections,
            appState: state,
            includeCredentials: false,
            passphrase: nil
        )
        return try ConnectionBundleCodec.decode(data)
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
        #expect(ConnectionBundleCodec.isEncrypted(data))
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

    @Test("An export writes the current file format and no saved queries")
    func exportWritesCurrentFormatWithoutQueries() async throws {
        let text = try await exportedText(includeCredentials: false)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])

        #expect(object["formatVersion"] as? Int == ConnectionBundle.formatVersion)
        #expect(!object.keys.contains("savedQueries"))
        #expect(!object.keys.contains("queryFolders"))
    }

    @Test("SSL modes export in the spelling the Mac reads")
    func exportWritesCanonicalSSLModes() async throws {
        let cases: [(mode: SSLConfiguration.SSLMode, expected: String)] = [
            (.require, "Required"),
            (.verifyCa, "Verify CA"),
            (.verifyFull, "Verify Identity")
        ]
        for entry in cases {
            let state = makeState()
            let connection = DatabaseConnection(
                name: "Secure",
                type: .postgresql,
                host: "10.0.0.5",
                sslEnabled: true,
                sslConfiguration: SSLConfiguration(mode: entry.mode)
            )
            let data = try await IOSConnectionExportService.exportData(
                connections: [connection],
                appState: state,
                includeCredentials: false,
                passphrase: nil
            )
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let connections = try #require(object["connections"] as? [[String: Any]])
            let ssl = try #require(connections.first?["sslConfig"] as? [String: Any])

            #expect(ssl["mode"] as? String == entry.expected, "\(entry.mode)")
        }
    }

    @Test("A connection with SSL off exports no SSL settings")
    func disabledSSLExportsNothing() throws {
        let connection = DatabaseConnection(
            name: "Plain",
            type: .postgresql,
            sslEnabled: true,
            sslConfiguration: SSLConfiguration(mode: .disable)
        )
        #expect(IOSConnectionExportService.portableSettings(for: connection).sslConfig == nil)
    }

    @Test("A connection in a nested group exports the whole group path")
    func exportKeepsNestedGroupPath() async throws {
        let state = makeState()
        let root = ConnectionGroup(name: "Client A", color: .blue)
        #expect(state.addGroup(root).isSaved)
        let leaf = ConnectionGroup(name: "Production", parentId: root.id)
        #expect(state.addGroup(leaf).isSaved)
        let connection = DatabaseConnection(name: "Orders", type: .postgresql, host: "db.example.com", groupId: leaf.id)
        #expect(state.addConnection(connection))

        let bundle = try await exportedBundle(state.connections, from: state)
        let exported = try #require(bundle.connections.first)
        let chain = bundle.groupChain(exported.groupRef)

        #expect(chain.map(\.name) == ["Client A", "Production"])
        #expect(chain.first?.color == "Blue")
    }

    @Test("Only the groups and tags of the exported connections go in the file")
    func exportCarriesOnlyUsedGroupsAndTags() async throws {
        let state = makeState()
        let used = ConnectionGroup(name: "Used")
        let unused = ConnectionGroup(name: "Unused")
        #expect(state.addGroup(used).isSaved)
        #expect(state.addGroup(unused).isSaved)
        let usedTag = ConnectionTag(name: "used-tag", color: .red)
        let unusedTag = ConnectionTag(name: "unused-tag")
        #expect(state.addTag(usedTag).isSaved)
        #expect(state.addTag(unusedTag).isSaved)
        let connection = DatabaseConnection(
            name: "Orders",
            type: .postgresql,
            host: "db.example.com",
            groupId: used.id,
            tagIds: [usedTag.id]
        )
        #expect(state.addConnection(connection))

        let bundle = try await exportedBundle(state.connections, from: state)

        #expect(bundle.groups.map(\.name) == ["Used"])
        #expect(bundle.tags.map(\.name) == ["used-tag"])
        #expect(bundle.tags.first?.color == "Red")
        #expect(bundle.connections.first?.tagNames == ["used-tag"])
    }

    @Test("An exported jump host keeps the auth method and key path it was synced with")
    func exportKeepsJumpHostCredentials() async throws {
        let state = makeState()
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
                        macAuthMethod: .privateKey,
                        macPrivateKeyPath: "~/.ssh/id_ed25519"
                    )
                ]
            )
        )
        #expect(state.addConnection(connection))

        let bundle = try await exportedBundle(state.connections, from: state)
        let hop = try #require(bundle.connections.first?.settings.sshConfig?.jumpHosts?.first)

        #expect(hop.host == "bastion-1")
        #expect(hop.port == nil)
        #expect(hop.authMethod == "Private Key")
        #expect(hop.privateKeyPath == "~/.ssh/id_ed25519")
    }

    @Test("An exported tunnel writes the port and auth method in the spellings macOS reads back")
    func exportWritesMacReadableTunnel() async throws {
        let state = makeState()
        let connection = DatabaseConnection(
            name: "Agent",
            type: .postgresql,
            host: "10.0.0.5",
            sshEnabled: true,
            sshConfiguration: SSHConfiguration(host: "db-1", username: "deploy", authMethod: .sshAgent)
        )
        #expect(state.addConnection(connection))

        let bundle = try await exportedBundle(state.connections, from: state)
        let ssh = try #require(bundle.connections.first?.settings.sshConfig)

        #expect(ssh.port == nil)
        #expect(ssh.authMethod == "SSH Agent")
    }

    @Test("Timeout overrides export explicitly and keep unrelated fields")
    func exportKeepsTimeoutOverrides() {
        var connection = DatabaseConnection(
            name: "Prod",
            type: .postgresql,
            queryTimeoutSeconds: 0,
            additionalFields: ["schema": "public"]
        )
        connection.connectTimeoutSeconds = 12

        let exported = IOSConnectionExportService.portableSettings(for: connection)

        #expect(exported.connectTimeoutSeconds == 12)
        #expect(exported.queryTimeoutSeconds == 0)
        #expect(exported.additionalFields == ["schema": "public"])
    }

    @Test("Export drops a query timeout unsafe for millisecond APIs")
    func exportDropsUnsafeQueryTimeout() {
        var connection = DatabaseConnection(name: "Prod", type: .postgresql)
        connection.queryTimeoutSeconds = DatabaseConnection.queryTimeoutSecondsRange.upperBound + 1

        #expect(IOSConnectionExportService.portableSettings(for: connection).queryTimeoutSeconds == nil)
    }

    @Test("An export leaves out the fields every importer drops and keeps the rest")
    func exportLeavesOutImportBlockedFields() {
        let connection = DatabaseConnection(
            name: "Scripted",
            type: .postgresql,
            host: "10.0.0.5",
            additionalFields: [
                "preConnectScript": "export PGTOKEN=secret-token",
                "usePgpass": "true",
                "promptForPassword": "true",
                "awsRegion": "us-east-1",
                "connectionOptions": "-c search_path=app"
            ]
        )

        let fields = IOSConnectionExportService.portableSettings(for: connection).additionalFields

        #expect(fields == ["connectionOptions": "-c search_path=app"])
    }

    @Test("suggested filename uses the connection name for a single export")
    func suggestedFilenameSingle() {
        let connection = DatabaseConnection(name: "Prod DB", type: .postgresql, host: "db", port: 5_432)
        #expect(IOSConnectionExportService.suggestedFilename(for: [connection]) == "Prod DB.tablepro")
    }

    @Test("suggested filename uses a generic name for multiple exports")
    func suggestedFilenameMultiple() {
        let a = DatabaseConnection(name: "A", type: .mysql, host: "a", port: 3_306)
        let b = DatabaseConnection(name: "B", type: .mysql, host: "b", port: 3_306)
        #expect(IOSConnectionExportService.suggestedFilename(for: [a, b]) == "TablePro Connections.tablepro")
    }
}
