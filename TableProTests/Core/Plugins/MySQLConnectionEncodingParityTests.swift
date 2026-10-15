//
//  MySQLConnectionEncodingParityTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct MySQLConnectionEncodingParityTests {
    @Test("MySQL and MariaDB curate the same encoding field the plugin declares")
    func curatedFieldsMatchThePlugin() throws {
        let declared = try BundledPlugin.driver("MySQLDriver").additionalConnectionFields
        let pluginField = try #require(declared.first { $0.id == "mysqlConnectionEncoding" })
        let expected = try Self.encoded(pluginField)
        let curated = PluginMetadataRegistry.curatedDefaults()
        for typeId in ["MySQL", "MariaDB"] {
            let snapshot = try #require(curated.first { $0.typeId == typeId }?.snapshot)
            let field = try #require(
                snapshot.connection.additionalConnectionFields.first { $0.id == pluginField.id },
                "\(typeId) curates no encoding field"
            )
            #expect(try Self.encoded(field) == expected, "\(typeId)")
        }
    }

    private static func encoded(_ field: ConnectionField) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(field)
    }
}
