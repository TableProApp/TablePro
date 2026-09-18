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

    /// The ClickHouse driver is one of the plugins bundled inside the app, and the test host is the
    /// app, so the factory resolves the real dialect here. This asserted an empty fallback on the
    /// premise that no plugin was loaded, which stopped being true and is why it sat in the
    /// quarantine file: the fallback is unreachable from a host that ships the driver.
    @Test("The factory resolves ClickHouse's dialect from the bundled plugin")
    @MainActor
    func testFactoryResolvesBundledDialect() {
        let dialect = SQLDialectFactory.createDialect(for: .clickhouse)

        #expect(!dialect.keywords.isEmpty)
        #expect(dialect.keywords.contains("OPTIMIZE"))
    }
}
