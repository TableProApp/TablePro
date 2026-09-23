//
//  SQLiteExtensionCallScannerTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("SQLite extension call scanner")
struct SQLiteExtensionCallScannerTests {
    private func onlyBuiltins(_ sql: String) -> Bool {
        SQLiteExtensionCallScanner.callsOnlyBuiltins(sql, readings: DatabaseType.sqlite.lexicalReadings)
    }

    @Test("Statements calling only SQLite's own functions and syntax pass")
    func builtinsPass() {
        let statements = [
            "SELECT 1",
            "SELECT abs(-1), lower(name), COUNT(*), coalesce(a, b) FROM t",
            "SELECT * FROM t WHERE id IN (1, 2) AND EXISTS (SELECT 1)",
            "SELECT CAST(x AS INTEGER) FROM t",
            "SELECT sum(x) OVER (PARTITION BY y) FROM t",
            "SELECT * FROM json_each('[1]'), pragma_table_info('t')",
            "INSERT INTO t VALUES (1), (2)",
            "SELECT \"abs\"(-1)",
            "SELECT [lower]('A')",
            "SELECT abs /* between */ (-1)",
            "SELECT * FROM v WHERE embedding MATCH '[1.0, 2.0]'",
            "SELECT 'vec_version(' || x FROM t -- vec_version()"
        ]
        for sql in statements {
            #expect(onlyBuiltins(sql), "\(sql)")
        }
    }

    @Test("A call to a function SQLite does not provide is caught, however it is spelled")
    func extensionCallsCaught() {
        let statements = [
            "SELECT vec_version()",
            "SELECT BlobToFile(x'00', '/tmp/a')",
            "SELECT * FROM t WHERE eval('DELETE FROM t') IS NULL",
            "SELECT \"vec_version\"()",
            "SELECT `vec_version`()",
            "SELECT [vec_version]()",
            "SELECT vec_version /* hidden */ ()",
            "SELECT vec_version\n()",
            "SELECT * FROM vec_each(x'00')",
            "SELECT * FROM main.vec_each(x'00')",
            "SELECT abs(vec_distance_l2(a, b)) FROM t"
        ]
        for sql in statements {
            #expect(!onlyBuiltins(sql), "\(sql)")
        }
    }

    @Test("A quoted callee the scanner cannot read cleanly counts against the statement")
    func unreadableQuotedCalleeIsRefused() {
        #expect(!onlyBuiltins("SELECT \"abs\" /* note */ (-1)"))
    }
}
