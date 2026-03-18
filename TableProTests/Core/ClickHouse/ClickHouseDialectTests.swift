//
//  ClickHouseDialectTests.swift
//  TableProTests
//
//  Tests for ClickHouse dialect descriptor structure
//

import Foundation
import Testing
@testable import TablePro
import TableProPluginKit

@Suite("ClickHouse Dialect")
struct ClickHouseDialectTests {

    @Test("SQLDialectDescriptor with ClickHouse-style config")
    func testClickHouseDialectDescriptor() {
        let descriptor = SQLDialectDescriptor(
            identifierQuote: "`",
            keywords: ["SELECT", "FINAL", "PREWHERE", "SAMPLE", "ENGINE"],
            functions: ["UNIQ", "ARGMIN", "TOPK"],
            dataTypes: ["UInt32", "String", "DateTime"]
        )
        let adapter = PluginDialectAdapter(descriptor: descriptor)

        #expect(adapter.identifierQuote == "`")
        #expect(adapter.keywords.contains("FINAL"))
        #expect(adapter.functions.contains("UNIQ"))
        #expect(adapter.dataTypes.contains("UInt32"))
    }

    @Test("Factory returns empty dialect when plugin not loaded")
    @MainActor
    func testFactoryFallbackWithoutPlugin() {
        let dialect = SQLDialectFactory.createDialect(for: .clickhouse)
        // Without plugin loaded, factory returns empty fallback
        #expect(dialect.keywords.isEmpty)
    }
}
