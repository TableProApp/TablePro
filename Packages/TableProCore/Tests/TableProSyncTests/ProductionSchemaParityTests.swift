import Foundation
import Testing

@testable import TableProSyncTransport

@Suite("Production CloudKit schema parity")
struct ProductionSchemaParityTests {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let schemaURL = repositoryRoot
        .appendingPathComponent("CloudKit")
        .appendingPathComponent("production-schema.ckdb")

    struct MissingRecordType: Error, CustomStringConvertible {
        let recordType: String

        var description: String {
            """
            No "RECORD TYPE \(recordType)" block in CloudKit/production-schema.ckdb. \
            The snapshot is stale or malformed, so nothing can be verified against it. \
            Re-export it with scripts/export-cloudkit-schema.sh and commit the result.
            """
        }
    }

    private static func snapshot() throws -> String {
        try String(contentsOf: schemaURL, encoding: .utf8)
    }

    private static func deployedRecordTypes() throws -> Set<String> {
        let contents = try snapshot()
        var names: Set<String> = []
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("RECORD TYPE ") else { continue }
            let remainder = trimmed.dropFirst("RECORD TYPE ".count)
            guard let name = remainder.components(separatedBy: .whitespaces).first, !name.isEmpty else { continue }
            names.insert(name)
        }
        return names
    }

    private static func fields(ofRecordType recordType: String) throws -> Set<String> {
        let contents = try snapshot()
        guard let block = contents
            .components(separatedBy: "RECORD TYPE \(recordType) (")
            .dropFirst()
            .first?
            .components(separatedBy: ");")
            .first
        else {
            throw MissingRecordType(recordType: recordType)
        }

        var names: Set<String> = []
        for line in block.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("\""), !trimmed.hasPrefix("GRANT") else { continue }
            guard let name = trimmed.components(separatedBy: .whitespaces).first, !name.isEmpty else { continue }
            names.insert(name)
        }
        return names
    }

    @Test("The exported production schema is checked in")
    func schemaSnapshotExists() {
        #expect(FileManager.default.fileExists(atPath: Self.schemaURL.path))
    }

    @Test("The snapshot parses into a recognisable Connection record")
    func snapshotParsesConnectionFields() throws {
        let deployed = try Self.fields(ofRecordType: "Connection")

        #expect(deployed.contains("connectionId"), """
        Parsed the Connection block but found no connectionId field, so the parser no longer \
        understands the snapshot format and every parity check below it would pass vacuously. \
        Parsed \(deployed.count) field(s): \(deployed.sorted()).
        """)
    }

    @Test("The snapshot parses into a recognisable set of record types")
    func snapshotParsesRecordTypes() throws {
        let deployed = try Self.deployedRecordTypes()

        #expect(deployed.contains("Connection"), """
        Parsed the snapshot but found no Connection record type, so the record-type parser no \
        longer understands the format and the checks below it would pass vacuously. \
        Parsed \(deployed.count) type(s): \(deployed.sorted()).
        """)
    }

    @Test("Every record type the app pushes exists in the production schema")
    func writableRecordTypesExistInProduction() throws {
        let deployed = try Self.deployedRecordTypes()
        let writable = Set(SyncRecordType.allCases.filter(\.isWritable).map(\.rawValue))
        let missing = writable.subtracting(deployed)

        #expect(missing.isEmpty, """
        Record types absent from the production schema: \(missing.sorted()). \
        CloudKit cannot create a record type outside the Development environment, so every \
        record of these types is rejected with "Cannot create new type … in production schema" \
        and stays dirty forever. Add each type in CloudKit Console, deploy Development to \
        Production, run scripts/export-cloudkit-schema.sh, and commit the refreshed snapshot. \
        Until then leave them out of SyncRecordType.verifiedInProduction.
        """)
    }

    @Test("A record type marked unverified is genuinely absent from the production schema")
    func unverifiedRecordTypesAreAbsentFromProduction() throws {
        let deployed = try Self.deployedRecordTypes()
        let unverified = Set(SyncRecordType.allCases.filter { !$0.isWritable }.map(\.rawValue))
        let deployedButGated = unverified.intersection(deployed)

        #expect(deployedButGated.isEmpty, """
        Deployed record types still gated off: \(deployedButGated.sorted()). \
        These exist in Production, so the gate is silently costing you data the app could sync. \
        Add them to SyncRecordType.verifiedInProduction.
        """)
    }

    @Test("Every field the app writes exists in the production schema", arguments: SyncRecordType.allCases)
    func writableFieldsExistInProduction(recordType: SyncRecordType) throws {
        guard recordType.isWritable else { return }
        let deployed = try Self.fields(ofRecordType: recordType.rawValue)
        let missing = recordType.writableFieldKeys.subtracting(deployed)

        #expect(missing.isEmpty, """
        Writable \(recordType.rawValue) fields absent from the production schema: \(missing.sorted()). \
        CloudKit rejects any record carrying an undeclared field, so these would stop \
        \(recordType.rawValue) syncing entirely. Add each field in CloudKit Console, deploy \
        Development to Production, run scripts/export-cloudkit-schema.sh, and commit the \
        refreshed snapshot. Until then leave them out of verifiedInProduction.
        """)
    }

    @Test("A field marked unverified is genuinely absent from production", arguments: SyncRecordType.allCases)
    func unverifiedFieldsAreAbsentFromProduction(recordType: SyncRecordType) throws {
        guard recordType.isWritable else { return }
        let deployed = try Self.fields(ofRecordType: recordType.rawValue)
        let unverified = recordType.declaredFieldKeys.subtracting(recordType.writableFieldKeys)
        let deployedButGated = unverified.intersection(deployed)

        #expect(deployedButGated.isEmpty, """
        Deployed \(recordType.rawValue) fields still gated off: \(deployedButGated.sorted()). \
        These exist in Production, so the gate is costing you data the app could sync. \
        Add them to verifiedInProduction.
        """)
    }
}
