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
