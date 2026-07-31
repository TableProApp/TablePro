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

    private static func fields(ofRecordType recordType: String) throws -> Set<String> {
        let contents = try String(contentsOf: schemaURL, encoding: .utf8)
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

    @Test("Every field the app writes exists in the production schema")
    func writableFieldsExistInProduction() throws {
        let deployed = try Self.fields(ofRecordType: "Connection")
        let missing = ConnectionSyncField.writableKeys.subtracting(deployed)

        #expect(missing.isEmpty, """
        Writable fields absent from the production schema: \(missing.sorted()). \
        CloudKit rejects any record carrying an undeclared field, so these would stop \
        Connection syncing entirely. Add each field in CloudKit Console, deploy Development \
        to Production, run scripts/export-cloudkit-schema.sh, and commit the refreshed snapshot. \
        Until then mark them unverified in ConnectionSyncSchema.swift.
        """)
    }

    @Test("A field marked unverified is genuinely absent from the production schema")
    func unverifiedFieldsAreAbsentFromProduction() throws {
        let deployed = try Self.fields(ofRecordType: "Connection")
        let unverified = ConnectionSyncField.declaredKeys.subtracting(ConnectionSyncField.writableKeys)
        let deployedButGated = unverified.intersection(deployed)

        #expect(deployedButGated.isEmpty, """
        Deployed fields still gated off: \(deployedButGated.sorted()). \
        These exist in Production, so the gate is costing you data the app could sync. \
        Mark them verified in ConnectionSyncSchema.swift.
        """)
    }
}
