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

    private static func fields(ofRecordType recordType: String) throws -> Set<String> {
        let contents = try String(contentsOf: schemaURL, encoding: .utf8)
        guard let block = contents
            .components(separatedBy: "RECORD TYPE \(recordType) (")
            .dropFirst()
            .first?
            .components(separatedBy: ");")
            .first
        else {
            return []
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

    @Test("Every field the app writes exists in the production schema")
    func writableFieldsExistInProduction() throws {
        let deployed = try Self.fields(ofRecordType: "Connection")
        let missing = ConnectionSyncField.writableKeys.subtracting(deployed)

        #expect(missing.isEmpty, "Writable fields absent from the production schema: \(missing.sorted())")
    }

    @Test("A field marked unverified is genuinely absent from the production schema")
    func unverifiedFieldsAreAbsentFromProduction() throws {
        let deployed = try Self.fields(ofRecordType: "Connection")
        let unverified = ConnectionSyncField.declaredKeys.subtracting(ConnectionSyncField.writableKeys)
        let deployedButGated = unverified.intersection(deployed)

        #expect(deployedButGated.isEmpty, "Deployed fields still gated off: \(deployedButGated.sorted())")
    }
}
