//
//  DriverPluginMetadataTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

// MARK: - EditorLanguage Tests

struct EditorLanguageTests {
    @Test("Custom case with associated value")
    func customCase() {
        let lang = EditorLanguage.custom("graphql")
        #expect(lang == EditorLanguage.custom("graphql"))
        #expect(lang != EditorLanguage.custom("cypher"))
        #expect(lang != EditorLanguage.sql)
    }

    @Test("Codable round-trip for all cases")
    func codable() throws {
        let cases: [EditorLanguage] = [.sql, .javascript, .bash, .custom("graphql")]
        for lang in cases {
            let data = try JSONEncoder().encode(lang)
            let decoded = try JSONDecoder().decode(EditorLanguage.self, from: data)
            #expect(decoded == lang)
        }
    }
}

struct RegistryAutoLimitStyleTests {
    private var defaults: [String: PluginMetadataSnapshot] {
        Dictionary(
            PluginMetadataRegistry.shared.registryPluginDefaults().map { ($0.typeId, $0.snapshot) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    @Test("Non-SQL plugins declare no SQL dialect so auto-limit resolves to none")
    func nonSqlPluginsHaveNoDialect() {
        #expect(defaults["MongoDB"]?.editor.sqlDialect == nil)
        #expect(defaults["Redis"]?.editor.sqlDialect == nil)
        #expect(defaults["etcd"]?.editor.sqlDialect == nil)
    }

    @Test("SQL plugins declare the auto-limit style matching their dialect")
    func sqlPluginsDeclareStyle() {
        #expect(defaults["SQL Server"]?.editor.sqlDialect?.autoLimitStyle == .top)
        #expect(defaults["Oracle"]?.editor.sqlDialect?.autoLimitStyle == .fetchFirst)
        #expect(defaults["Dameng"]?.editor.sqlDialect?.autoLimitStyle == .fetchFirst)
        #expect(defaults["ClickHouse"]?.editor.sqlDialect?.autoLimitStyle == .limit)
        #expect(defaults["DuckDB"]?.editor.sqlDialect?.autoLimitStyle == .limit)
        #expect(defaults["Cassandra"]?.editor.sqlDialect?.autoLimitStyle == .limit)
        #expect(defaults["Cloudflare D1"]?.editor.sqlDialect?.autoLimitStyle == .limit)
        #expect(defaults["libSQL"]?.editor.sqlDialect?.autoLimitStyle == .limit)
    }

    @Test("Registry entries declare the plan format their parser reads")
    func registryEntriesDeclareExplainFormat() {
        #expect(defaults["Dameng"]?.explainVariants.first?.format == .damengText)
        #expect(defaults["ClickHouse"]?.explainVariants.first?.format == .indentedText)
        #expect(defaults["DuckDB"]?.explainVariants.first?.format == .indentedText)
    }
}
