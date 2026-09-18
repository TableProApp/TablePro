//
//  MySQLConnectionEncodingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("MySQL connection encoding")
struct MySQLConnectionEncodingTests {
    @Test("A missing, empty or unknown field value is plain UTF-8")
    func fieldValueParsing() {
        #expect(MySQLConnectionEncoding(fieldValue: nil) == .utf8)
        #expect(MySQLConnectionEncoding(fieldValue: "") == .utf8)
        #expect(MySQLConnectionEncoding(fieldValue: "sjis") == .utf8)
        #expect(MySQLConnectionEncoding(fieldValue: "utf8ViaLatin1") == .utf8ViaLatin1)
    }

    @Test("The connection's additional fields resolve to an encoding")
    func additionalFieldsParsing() {
        #expect(MySQLConnectionEncoding(additionalFields: [:]) == .utf8)
        #expect(MySQLConnectionEncoding(additionalFields: ["mysqlConnectionEncoding": "utf8ViaLatin1"]) == .utf8ViaLatin1)
        #expect(MySQLConnectionEncoding(additionalFields: ["other": "utf8ViaLatin1"]) == .utf8)
    }

    @Test("Only UTF-8 via Latin 1 changes the client character set, and only the client's")
    func sessionStatements() {
        #expect(MySQLConnectionEncoding.utf8.sessionStatements.isEmpty)
        #expect(MySQLConnectionEncoding.utf8ViaLatin1.sessionStatements == ["SET character_set_client = latin1"])
        #expect(MySQLConnectionEncoding.sessionCharacterSetName == "utf8mb4")
        #expect(MySQLConnectionEncoding.sessionFallbackStatement == "SET NAMES utf8")
    }

    @Test("The field is an advanced dropdown whose values the driver reads back")
    func fieldShape() throws {
        let field = MySQLConnectionEncoding.connectionField
        #expect(field.id == MySQLConnectionEncoding.fieldId)
        #expect(field.section == .advanced)
        guard case .dropdown(let options) = field.fieldType else {
            Issue.record("expected a dropdown")
            return
        }
        #expect(options.map(\.value) == MySQLConnectionEncoding.allCases.map(\.rawValue))
        for option in options {
            #expect(MySQLConnectionEncoding(fieldValue: option.value).rawValue == option.value)
        }
    }

    @Test("MySQL and MariaDB curate the same encoding field the plugin declares")
    func curatedFieldsMatchThePlugin() throws {
        let expected = try Self.encoded(MySQLConnectionEncoding.connectionField)
        let curated = PluginMetadataRegistry.curatedDefaults()
        for typeId in ["MySQL", "MariaDB"] {
            let snapshot = try #require(curated.first { $0.typeId == typeId }?.snapshot)
            let field = try #require(
                snapshot.connection.additionalConnectionFields.first { $0.id == MySQLConnectionEncoding.fieldId },
                "\(typeId) curates no encoding field"
            )
            #expect(try Self.encoded(field) == expected, "\(typeId)")
        }
    }

    @Test("The MySQL plugin declares the shared encoding field")
    func pluginDeclaresTheField() throws {
        let source = try String(contentsOf: Self.repositoryRoot().appendingPathComponent(
            "Plugins/MySQLDriverPlugin/MySQLPlugin.swift"
        ), encoding: .utf8)
        #expect(source.contains("MySQLConnectionEncoding.connectionField"))
    }

    private static func encoded(_ field: ConnectionField) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(field)
    }

    private static func repositoryRoot(file: StaticString = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("project.yml").path) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
