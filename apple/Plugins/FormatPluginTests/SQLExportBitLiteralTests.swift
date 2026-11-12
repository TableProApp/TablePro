import Foundation
import TableProPluginKit
import Testing

// MySQL stores a quoted literal's bytes in a BIT column: '5' restores as 53.
struct SQLExportBitLiteralTests {
    private func encoder(databaseTypeId: String, types: [String] = ["BIT", "VARCHAR"]) -> SQLExportRowValueEncoder {
        SQLExportRowValueEncoder(
            columns: ["b", "s"],
            columnTypeNames: types,
            excludedColumnNames: [],
            databaseTypeId: databaseTypeId,
            escapeStringLiteral: { $0.replacingOccurrences(of: "'", with: "''") }
        )
    }

    @Test("A MySQL-family BIT value is written as a bare number", arguments: ["MySQL", "MariaDB", "TiDB", "OceanBase"])
    func bitIsANumber(databaseTypeId: String) {
        let row = encoder(databaseTypeId: databaseTypeId).render([.text("5"), .text("5")])
        #expect(row == "  (5, '5')")
    }

    @Test("A BIT(64) value keeps every digit")
    func widestBit() {
        let row = encoder(databaseTypeId: "MySQL", types: ["BIT(64)", "VARCHAR"])
            .render([.text("18446744073709551615"), .text("x")])
        #expect(row == "  (18446744073709551615, 'x')")
    }

    @Test("NULL stays NULL and text that is no number stays quoted")
    func otherValues() {
        let mysql = encoder(databaseTypeId: "MySQL")
        #expect(mysql.render([.null, .text("a")]) == "  (NULL, 'a')")
        #expect(mysql.render([.text("-1"), .text("a")]) == "  ('-1', 'a')")
        #expect(mysql.render([.text("1e3"), .text("a")]) == "  ('1e3', 'a')")
        #expect(mysql.render([.text(""), .text("a")]) == "  ('', 'a')")
    }

    @Test("A PostgreSQL bit string stays a quoted literal")
    func postgresBitStaysQuoted() {
        let row = encoder(databaseTypeId: "PostgreSQL", types: ["bit", "varchar"]).render([.text("101"), .text("x")])
        #expect(row == "  ('101', 'x')")
    }

    @Test("StarRocks BITMAP is not BIT")
    func bitmapStaysQuoted() {
        let row = encoder(databaseTypeId: "StarRocks", types: ["BITMAP", "VARCHAR"]).render([.text("7"), .text("x")])
        #expect(row == "  ('7', 'x')")
    }
}
