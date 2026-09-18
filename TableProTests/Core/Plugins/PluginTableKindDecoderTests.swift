//
//  PluginTableKindDecoderTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("Plugin table kind decoder")
struct PluginTableKindDecoderTests {
    @Test("Every table-like spelling a driver sends decodes to its own kind")
    func knownSpellingsDecode() {
        let expected: [String: TableInfo.TableType] = [
            "TABLE": .table,
            "BASE TABLE": .table,
            "PREFIX": .table,
            "PARTITIONED TABLE": .partitionedTable,
            "VIEW": .view,
            "MATERIALIZED VIEW": .materializedView,
            "FOREIGN TABLE": .foreignTable,
            "SYSTEM TABLE": .systemTable,
            "SYSTEM BASE TABLE": .systemTable,
            "SYSTEM VIEW": .systemTable,
            "EXTERNAL TABLE": .externalTable,
            "SEQUENCE": .sequence
        ]

        for (spelling, kind) in expected {
            let decoded = PluginTableKindDecoder.decode(spelling)
            #expect(decoded.kind == kind, "\(spelling) decoded to \(String(describing: decoded.kind))")
            #expect(!decoded.isSystemVersioned, "\(spelling) claimed system versioning")
        }
    }

    /// Measured on MariaDB 11.4.13: `information_schema.TABLES` reports `SYSTEM VERSIONED` for a
    /// table declared `WITH SYSTEM VERSIONING`, whether or not it is partitioned, so the kind and
    /// the trait have to arrive separately.
    @Test("System versioning arrives as a trait beside an ordinary kind")
    func systemVersionedSpellingsCarryTheTrait() {
        let plain = PluginTableKindDecoder.decode("SYSTEM VERSIONED")
        #expect(plain.kind == .table)
        #expect(plain.isSystemVersioned)

        let named = PluginTableKindDecoder.decode("SYSTEM VERSIONED TABLE")
        #expect(named.kind == .table)
        #expect(named.isSystemVersioned)

        let partitioned = PluginTableKindDecoder.decode("SYSTEM VERSIONED PARTITIONED TABLE")
        #expect(partitioned.kind == .partitionedTable)
        #expect(partitioned.isSystemVersioned)
    }

    @Test("Case and underscores do not change the answer")
    func spellingIsNormalized() {
        #expect(PluginTableKindDecoder.decode("base_table").kind == .table)
        #expect(PluginTableKindDecoder.decode("Materialized_View").kind == .materializedView)
        #expect(PluginTableKindDecoder.decode("system versioned").isSystemVersioned)
        #expect(PluginTableKindDecoder.decode("  SYSTEM   VERSIONED  ").isSystemVersioned)
    }

    /// The vocabulary is exact spellings rather than a substring scan, so a driver that says
    /// something else is logged and defaulted by the adapter instead of silently losing Truncate.
    @Test("An unknown spelling decodes to no kind and no trait")
    func unknownSpellingsDecodeToNil() {
        for spelling in ["", "widget", "SYSTEM VERSIONED FOREIGN TABLE", "TEMPORARY"] {
            let decoded = PluginTableKindDecoder.decode(spelling)
            #expect(decoded.kind == nil, "\(spelling) should not decode")
            #expect(!decoded.isSystemVersioned, "\(spelling) should carry no trait")
        }
    }
}
