//
//  PostgreSQLFamilyConnectionFieldTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct PostgreSQLFamilyConnectionFieldTests {
    private static let pgpassFieldId = "usePgpass"

    private static let pluginSource: URL = {
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { directory.deleteLastPathComponent() }
        return directory
            .appendingPathComponent("Plugins")
            .appendingPathComponent("PostgreSQLDriverPlugin")
            .appendingPathComponent("PostgreSQLPlugin.swift")
    }()

    private static func curatedPgpassLabel(for type: DatabaseType) -> String? {
        PluginMetadataRegistry.shared.snapshot(for: type)?
            .connection.additionalConnectionFields
            .first { $0.id == pgpassFieldId }?
            .label
    }

    private static func pluginPgpassLabel() throws -> String? {
        let source = try String(contentsOf: pluginSource, encoding: .utf8)
        let pattern = #"id: "usePgpass",\s*label: String\(localized: "([^"]+)"\)"#
        let range = NSRange(location: 0, length: (source as NSString).length)
        guard let match = try NSRegularExpression(pattern: pattern).firstMatch(in: source, range: range) else {
            return nil
        }
        return (source as NSString).substring(with: match.range(at: 1))
    }

    @Test("The ~/.pgpass toggle has the plugin's name on every PostgreSQL-family type")
    func everyTypeUsesThePluginLabel() throws {
        let pluginLabel = try #require(try Self.pluginPgpassLabel())
        #expect(pluginLabel == "Use ~/.pgpass")
        for type in [DatabaseType.postgresql, .redshift, .cockroachdb] {
            #expect(Self.curatedPgpassLabel(for: type) == pluginLabel)
        }
    }
}
