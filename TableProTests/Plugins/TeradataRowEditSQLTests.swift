//
//  TeradataRowEditSQLTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct TeradataRowEditSQLTests {
    @Test
    func insertLeavesDefaultMarkedColumnsOut() {
        let sql = TeradataRowEditSQL.insert(
            target: "\"db\".\"t\"",
            columns: ["id", "status", "note"],
            values: [.text("1"), .text("__DEFAULT__"), .text("it's")]
        )
        #expect(sql == "INSERT INTO \"db\".\"t\" (\"id\", \"note\") VALUES ('1', 'it''s')")
    }

    @Test
    func insertOfOnlyDefaultsUsesDefaultValues() {
        let sql = TeradataRowEditSQL.insert(
            target: "\"db\".\"t\"", columns: ["id"], values: [.text("__DEFAULT__")]
        )
        #expect(sql == "INSERT INTO \"db\".\"t\" DEFAULT VALUES")
    }

    @Test
    func literalsCoverNullTextAndBytes() {
        #expect(TeradataRowEditSQL.literal(.null) == "NULL")
        #expect(TeradataRowEditSQL.literal(.text("a'b")) == "'a''b'")
        #expect(TeradataRowEditSQL.literal(.bytes(Data([0x0A, 0xFF]))) == "'0AFF'XB")
    }
}
