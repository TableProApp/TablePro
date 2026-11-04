//
//  ConnectionOriginTests.swift
//  TableProTests
//

import CloudKit
import Foundation
@testable import TablePro
import TableProImport
import TableProPluginKit
import TableProSyncTransport
import Testing

@MainActor
struct ConnectionOriginTests {
    private static let zoneID = CKRecordZone.ID(zoneName: "TableProSync", ownerName: CKCurrentUserDefaultName)

    private func pair() -> (thisMac: DatabaseConnection, imported: DatabaseConnection) {
        let own = DatabaseConnection(
            name: "Staging",
            host: "pg.example.com",
            port: 5_432,
            database: "${APP_DB}",
            username: "$APP_USER",
            type: .postgresql
        )
        var imported = own
        imported.origin = .imported
        return (own, imported)
    }

    @Test("A connections.json row with no origin reads as made on this Mac, and that origin writes no key")
    func absentKeyIsThisMac() throws {
        let data = try JSONEncoder().encode(StoredConnection(from: DatabaseConnection(name: "Own")))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["origin"] == nil)
        #expect(try JSONDecoder().decode(StoredConnection.self, from: data).toConnection().origin == .thisMac)
    }

    @Test("An origin this build does not know reads as made on this Mac")
    func unknownValueIsThisMac() throws {
        let data = try JSONEncoder().encode(StoredConnection(from: pair().imported))
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["origin"] as? String == "imported")
        object["origin"] = "fromTheFuture"

        let edited = try JSONSerialization.data(withJSONObject: object)

        #expect(try JSONDecoder().decode(StoredConnection.self, from: edited).toConnection().origin == .thisMac)
    }

    @Test("A pulled or replaced definition keeps the origin this Mac recorded")
    func deviceLocalStateKeepsTheOrigin() {
        var pulled = pair().thisMac
        pulled.origin = .synced
        let local = pair().imported

        #expect(pulled.adoptingDeviceLocalState(from: local).origin == .imported)
    }

    @Test("The origin never reaches the CloudKit record")
    func cloudKitRecordCarriesNoOrigin() {
        let (own, imported) = pair()
        let ownRecord = SyncRecordMapper.toCKRecord(own, in: Self.zoneID)
        let importedRecord = SyncRecordMapper.toCKRecord(imported, in: Self.zoneID)

        #expect(Set(importedRecord.allKeys()) == Set(ownRecord.allKeys()))
        #expect(!importedRecord.allKeys().contains { $0.localizedCaseInsensitiveContains("origin") })
        for key in importedRecord.allKeys() where key != ConnectionSyncField.modifiedAtLocal.key {
            let left = importedRecord[key] as? NSObject
            let right = ownRecord[key] as? NSObject
            #expect(left == right, "\(key)")
        }
    }

    @Test("The origin never reaches an export, a share link or a team library entry")
    func exportCarriesNoOrigin() throws {
        let (own, imported) = pair()
        let exporter = ConnectionBundleExporter()

        let ownSettings = exporter.portableSettings(for: own)
        let importedSettings = exporter.portableSettings(for: imported)
        let encoded = try JSONEncoder().encode(importedSettings)
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(importedSettings == ownSettings)
        #expect(!object.keys.contains { $0.localizedCaseInsensitiveContains("origin") })
    }

    @Test("Linked folder, team library and link connections say where they came from")
    func transientOriginsAreSet() throws {
        let linked = LinkedConnection(
            id: UUID(),
            connection: ExportableConnection(
                name: "Shared",
                host: "db.example.com",
                port: 5_432,
                database: "app",
                username: "reader",
                type: DatabaseType.postgresql.rawValue
            ),
            folderId: UUID(),
            sourceFileURL: URL(fileURLWithPath: "/tmp/shared.tablepro")
        )
        #expect(linked.databaseConnection().origin == .linkedFolder)
        #expect(linked.databaseConnection(origin: .teamLibrary).origin == .teamLibrary)

        guard case .success(let parsed) = ConnectionURLParser.parse("postgresql://db.example.com:5432/app") else {
            Issue.record("The URL did not parse")
            return
        }
        #expect(TransientConnectionFactory.build(from: parsed).origin == .link)
    }
}
