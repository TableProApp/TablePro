import Foundation
import TableProDatabase
import TableProImport
import TableProModels
import Testing

@testable import TableProMobile

@MainActor
@Suite("iOS Connection Import/Export Service")
struct IOSConnectionImportServiceTests {
    @Test("restores credentials to the iOS keychain key format for mapped connections only")
    func restoresCredentialsForMappedIndices() throws {
        let idA = UUID()
        let idB = UUID()
        let store = MockSecureStore()

        let envelope = ConnectionExportEnvelope(
            formatVersion: 1, exportedAt: Date(), appVersion: "Tests",
            connections: [],
            groups: nil, tags: nil,
            credentials: [
                "0": ExportableCredentials(
                    password: "pw0", sshPassword: "ssh0", keyPassphrase: "key0",
                    sslClientKeyPassphrase: nil, totpSecret: nil, pluginSecureFields: nil
                ),
                "1": ExportableCredentials(
                    password: "pw1", sshPassword: nil, keyPassphrase: nil,
                    sslClientKeyPassphrase: nil, totpSecret: nil, pluginSecureFields: nil
                ),
                "2": ExportableCredentials(
                    password: "orphan", sshPassword: nil, keyPassphrase: nil,
                    sslClientKeyPassphrase: nil, totpSecret: nil, pluginSecureFields: nil
                ),
            ]
        )

        IOSConnectionImportService.restoreCredentials(
            from: envelope,
            connectionIdMap: [0: idA, 1: idB],
            secureStore: store
        )

        #expect(try store.retrieve(forKey: "com.TablePro.password.\(idA.uuidString)") == "pw0")
        #expect(try store.retrieve(forKey: "com.TablePro.sshpassword.\(idA.uuidString)") == "ssh0")
        #expect(try store.retrieve(forKey: "com.TablePro.keypassphrase.\(idA.uuidString)") == "key0")
        #expect(try store.retrieve(forKey: "com.TablePro.password.\(idB.uuidString)") == "pw1")
        #expect(try store.retrieve(forKey: "com.TablePro.sshpassword.\(idB.uuidString)") == nil)
    }

    @Test("recognizes every known type plus the variants a Mac export can carry")
    func recognizesVariantTypes() {
        let recognized = IOSConnectionImportService.recognizedTypeIds
        #expect(DatabaseType.allKnownTypes.allSatisfy { recognized.contains($0.rawValue) })
        #expect(recognized.isSuperset(of: ["CockroachDB", "ScyllaDB", "Turso"]))
        #expect(!recognized.contains("Vertica"))
    }

    @Test("no credentials envelope writes nothing")
    func noCredentialsWritesNothing() throws {
        let store = MockSecureStore()
        let id = UUID()
        let envelope = ConnectionExportEnvelope(
            formatVersion: 1, exportedAt: Date(), appVersion: "Tests",
            connections: [], groups: nil, tags: nil, credentials: nil
        )
        IOSConnectionImportService.restoreCredentials(from: envelope, connectionIdMap: [0: id], secureStore: store)
        #expect(try store.retrieve(forKey: "com.TablePro.password.\(id.uuidString)") == nil)
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

@MainActor
@Suite("iOS connection import replace")
struct IOSConnectionImportReplaceTests {
    private let fixture: AppStateFixture
    private let store = MockSecureStore()
    private let appState: AppState
    private let existing = DatabaseConnection(
        name: "Bastion",
        type: .postgresql,
        host: "db.example.com",
        port: 5_432,
        sshEnabled: true,
        sshConfiguration: SSHConfiguration(host: "bastion.example.com", username: "deploy", authMethod: .privateKey)
    )

    init() throws {
        fixture = try AppStateFixture()
        appState = fixture.makeState(syncEnabled: false, secureStore: store)
    }

    private var keyAccount: String {
        ConnectionSecretKind.sshPrivateKey.account(for: existing.id)
    }

    private func tunnel(authMethod: String, keyPath: String = "") -> ExportableSSHConfig {
        ExportableSSHConfig(
            enabled: true, host: "bastion.example.com", port: 22, username: "deploy",
            authMethod: authMethod, privateKeyPath: keyPath, agentSocketPath: "", jumpHosts: nil,
            totpMode: nil, totpAlgorithm: nil, totpDigits: nil, totpPeriod: nil
        )
    }

    private func replaceExisting(with ssh: ExportableSSHConfig?) -> Int {
        let imported = ExportableConnection(
            name: existing.name, host: existing.host, port: existing.port, database: "", username: "",
            type: DatabaseType.postgresql.rawValue, sshConfig: ssh, sslConfig: nil, color: nil, tagName: nil,
            groupName: nil, sshProfileId: nil, safeModeLevel: nil, aiPolicy: nil, additionalFields: nil,
            redisDatabase: nil, startupCommands: nil, localOnly: nil
        )
        let item = ImportItem(
            connection: imported,
            status: .duplicate(existingId: existing.id, existingName: existing.name)
        )
        let envelope = ConnectionExportEnvelope(
            formatVersion: 1, exportedAt: Date(), appVersion: "Tests",
            connections: [imported], groups: nil, tags: nil, credentials: nil
        )
        return IOSConnectionImportService.performImport(
            ConnectionImportPreview(envelope: envelope, items: [item]),
            resolutions: [item.id: .replace(existingId: existing.id)],
            appState: appState
        ).importedCount
    }

    @Test("Replacing a connection keeps its pasted key, whatever tunnel the import brings")
    func replaceKeepsPastedKey() throws {
        #expect(appState.addConnection(existing))
        let incoming: [ExportableSSHConfig?] = [
            tunnel(authMethod: "privateKey"),
            tunnel(authMethod: "privateKey", keyPath: "~/.ssh/id_ed25519"),
            tunnel(authMethod: "password"),
            nil
        ]

        for ssh in incoming {
            store.seed(keyAccount, "PASTED KEY")

            #expect(replaceExisting(with: ssh) == 1)

            #expect(try store.retrieve(forKey: keyAccount) == "PASTED KEY", "\(ssh?.authMethod ?? "no tunnel")")
        }
    }
}
