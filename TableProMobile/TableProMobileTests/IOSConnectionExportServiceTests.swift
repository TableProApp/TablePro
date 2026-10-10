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
                        macAuthMethod: .privateKey,
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

    @Test("An exported tunnel writes the port and auth method in the spellings macOS reads back")
    func exportWritesMacReadableTunnel() async throws {
        let state = makeState(secureStore: MockSecureStore())
        let connection = DatabaseConnection(
            name: "Agent",
            type: .postgresql,
            host: "10.0.0.5",
            sshEnabled: true,
            sshConfiguration: SSHConfiguration(host: "db-1", username: "deploy", authMethod: .sshAgent)
        )
        #expect(state.addConnection(connection))

        let data = try await IOSConnectionExportService.exportData(
            connections: state.connections,
            appState: state,
            includeCredentials: false,
            passphrase: nil
        )
        let envelope = try ConnectionImportDecoder.decodeData(data)
        let ssh = try #require(envelope.connections.first?.sshConfig)

        #expect(ssh.port == nil)
        #expect(ssh.authMethod == "SSH Agent")
    }

    @Test("Timeout overrides export explicitly and keep unrelated fields")
    func exportKeepsTimeoutOverrides() throws {
        let state = makeState(secureStore: MockSecureStore())
        var connection = DatabaseConnection(
            name: "Prod",
            type: .postgresql,
            queryTimeoutSeconds: 0,
            additionalFields: ["schema": "public"]
        )
        connection.connectTimeoutSeconds = 12

        let exported = try #require(IOSConnectionExportService.buildEnvelope([connection], appState: state).connections.first)

        #expect(exported.connectTimeoutSeconds == 12)
        #expect(exported.queryTimeoutSeconds == 0)
        #expect(exported.additionalFields == ["schema": "public"])
    }

    @Test("Export drops a query timeout unsafe for millisecond APIs")
    func exportDropsUnsafeQueryTimeout() throws {
        let state = makeState(secureStore: MockSecureStore())
        var connection = DatabaseConnection(name: "Prod", type: .postgresql)
        connection.queryTimeoutSeconds = DatabaseConnection.queryTimeoutSecondsRange.upperBound + 1

        let exported = try #require(
            IOSConnectionExportService.buildEnvelope([connection], appState: state).connections.first
        )

        #expect(exported.queryTimeoutSeconds == nil)
    }

    @Test("An export leaves out the fields every importer drops and keeps the rest")
    func exportLeavesOutImportBlockedFields() throws {
        let state = makeState(secureStore: MockSecureStore())
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
        #expect(state.addConnection(connection))

        let envelope = IOSConnectionExportService.buildEnvelope([connection], appState: state)
        let fields = try #require(envelope.connections.first?.additionalFields)

        #expect(fields == ["connectionOptions": "-c search_path=app"])
    }

    @Test("An export carries the connection icon, and no icon key when there is none")
    func exportCarriesConnectionIcon() throws {
        let state = makeState(secureStore: MockSecureStore())
        let withIcon = DatabaseConnection(name: "Prod", type: .postgresql, iconName: "flame")
        let withoutIcon = DatabaseConnection(name: "Dev", type: .postgresql)

        let exported = IOSConnectionExportService.buildEnvelope([withIcon, withoutIcon], appState: state).connections

        #expect(exported.map(\.iconName) == ["flame", nil])
    }

    @Test("A group exports its colour and icon from the connection's own group, not another of the same name")
    func exportResolvesGroupById() throws {
        let state = makeState(secureStore: MockSecureStore())
        let clientA = ConnectionGroup(name: "Client A")
        let clientB = ConnectionGroup(name: "Client B")
        let prodA = ConnectionGroup(name: "Prod", color: .red, iconName: "briefcase", parentId: clientA.id)
        let prodB = ConnectionGroup(name: "Prod", color: .blue, iconName: "flame", parentId: clientB.id)
        for group in [clientA, clientB, prodA, prodB] {
            #expect(state.addGroup(group) == .applied)
        }
        let inB = DatabaseConnection(name: "B", type: .postgresql, groupId: prodB.id)
        let inA = DatabaseConnection(name: "A", type: .postgresql, groupId: prodA.id)

        let envelope = IOSConnectionExportService.buildEnvelope([inB, inA], appState: state)
        let groups = try #require(envelope.groups)

        #expect(groups.map(\.name) == ["Prod"])
        #expect(groups.first?.color == ConnectionColor.blue.rawValue)
        #expect(groups.first?.iconName == "flame")
        #expect(envelope.connections.map(\.groupName) == ["Prod", "Prod"])
    }

    @Test("Exported groups follow export order and leave out a group no exported connection uses")
    func exportGroupsFollowExportOrder() throws {
        let state = makeState(secureStore: MockSecureStore())
        let work = ConnectionGroup(name: "Work", iconName: "building.2")
        let home = ConnectionGroup(name: "Home", color: .green)
        let unused = ConnectionGroup(name: "Unused")
        for group in [work, home, unused] {
            #expect(state.addGroup(group) == .applied)
        }
        let connections = [
            DatabaseConnection(name: "Home DB", type: .mysql, groupId: home.id),
            DatabaseConnection(name: "Work DB", type: .mysql, groupId: work.id),
            DatabaseConnection(name: "Loose", type: .mysql)
        ]

        let groups = try #require(IOSConnectionExportService.buildEnvelope(connections, appState: state).groups)

        #expect(groups.map(\.name) == ["Home", "Work"])
        #expect(groups.map(\.color) == [ConnectionColor.green.rawValue, nil])
        #expect(groups.map(\.iconName) == [nil, "building.2"])
    }

    @Test("An export with no grouped connection writes no groups")
    func exportWithoutGroupsWritesNone() {
        let state = makeState(secureStore: MockSecureStore())

        let envelope = IOSConnectionExportService.buildEnvelope(
            [DatabaseConnection(name: "Loose", type: .mysql)],
            appState: state
        )

        #expect(envelope.groups == nil)
    }
}
