import CloudKit
import Foundation
import Testing

@testable import TableProSyncTransport

@Suite("Sync schema gate")
struct SyncSchemaGateTests {
    private enum SampleField: String, SyncSchemaField {
        case deployed
        case undeployed

        static let verifiedInProduction: Set<Self> = [.deployed]
    }

    private static let zoneID = CKRecordZone.ID(zoneName: "TableProSync", ownerName: CKCurrentUserDefaultName)

    private static func record(ofType type: SyncRecordType, id: String) -> CKRecord {
        CKRecord(
            recordType: type.rawValue,
            recordID: CKRecord.ID(recordName: type.recordName(for: id), zoneID: zoneID)
        )
    }

    @Test("A verified field is written to the record")
    func verifiedFieldIsWritten() {
        let record = Self.record(ofType: .connection, id: "a")
        let fields = record.fields(SampleField.self)

        fields[.deployed] = "value"

        #expect(record["deployed"] as? String == "value")
    }

    @Test("An unverified field is refused, so CloudKit never sees an undeclared key")
    func unverifiedFieldIsRefused() {
        let record = Self.record(ofType: .connection, id: "a")
        let fields = record.fields(SampleField.self)

        fields[.undeployed] = "value"

        #expect(record["undeployed"] == nil)
        #expect(fields[.undeployed] == nil)
    }

    @Test("Writable keys exclude unverified fields")
    func writableKeysExcludeUnverified() {
        #expect(SampleField.writableKeys == ["deployed"])
        #expect(SampleField.declaredKeys == ["deployed", "undeployed"])
    }

    @Test("A field added without a deploy is inert by default")
    func newFieldDefaultsToUnverified() {
        #expect(SampleField.undeployed.productionSchemaState == .unverified)
        #expect(SampleField.undeployed.isWritable == false)
        #expect(SampleField.deployed.productionSchemaState == .verified)
    }

    @Test("Every record type the app declares is currently deployed")
    func allRecordTypesAreWritable() {
        let gated = SyncRecordType.allCases.filter { !$0.isWritable }

        #expect(gated.isEmpty, "Gated record types: \(gated.map(\.rawValue).sorted())")
    }

    @Test("Records of a deployed type are published")
    func deployedRecordsArePublished() {
        let records = [Self.record(ofType: .connection, id: "a"), Self.record(ofType: .tableFavorite, id: "b")]

        #expect(SyncSchemaGate.publishable(records: records).count == 2)
        #expect(SyncSchemaGate.withheldRecordTypes(in: records).isEmpty)
    }

    @Test("Records of an unknown type are withheld rather than pushed")
    func unknownRecordTypesAreWithheld() {
        let known = Self.record(ofType: .connection, id: "a")
        let unknown = CKRecord(
            recordType: "NotInTheSchema",
            recordID: CKRecord.ID(recordName: "NotInTheSchema_1", zoneID: Self.zoneID)
        )

        let publishable = SyncSchemaGate.publishable(records: [known, unknown])

        #expect(publishable.map(\.recordType) == ["Connection"])
        #expect(SyncSchemaGate.withheldRecordTypes(in: [known, unknown]) == ["NotInTheSchema"])
    }

    @Test("Deletions for an unknown type are withheld")
    func unknownDeletionsAreWithheld() {
        let known = Self.record(ofType: .tableFavorite, id: "b").recordID
        let unknown = CKRecord.ID(recordName: "NotInTheSchema_1", zoneID: Self.zoneID)

        #expect(SyncSchemaGate.publishable(deletions: [known, unknown]) == [known])
    }

    @Test("Every record type resolves its own field registry")
    func everyRecordTypeDeclaresFields() {
        for type in SyncRecordType.allCases {
            #expect(!type.declaredFieldKeys.isEmpty, "\(type.rawValue) declares no fields")
            #expect(type.writableFieldKeys.isSubset(of: type.declaredFieldKeys))
        }
    }
}
