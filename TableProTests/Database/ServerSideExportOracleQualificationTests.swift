//
//  ServerSideExportOracleQualificationTests.swift
//  TableProTests
//
//  The Oracle server-side export block reaches DBMS_DATAPUMP only through a SQL-level CALL, so a package named SYS in
//  the schema the session runs under cannot capture it. Measured on Oracle 23ai: the bare-name block ran an
//  attacker-planted DBMS_DATAPUMP with the reader's privileges; the CALL form reached the real package.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

struct ServerSideExportOracleQualificationTests {
    private func oracleStatement(table: String = "ORDERS", schema: String? = nil) -> String {
        ServerSideExport.statement(
            for: ServerSideExport.Request(
                table: table, schema: schema, destination: .oracleDirectory(name: "DP_DIR"), format: .csv),
            databaseType: .oracle,
            quoteIdentifier: { "\"\($0)\"" },
            escapeLiteral: { $0.replacingOccurrences(of: "'", with: "''") }
        ) ?? ""
    }

    @Test("Every DBMS_DATAPUMP call goes through a SQL-level CALL")
    func everyCallIsSqlLevel() {
        let sql = oracleStatement()
        let mentions = sql.components(separatedBy: "DBMS_DATAPUMP").count - 1
        let throughCall = sql.components(separatedBy: "CALL SYS.DBMS_DATAPUMP").count - 1
        #expect(mentions > 0)
        #expect(mentions == throughCall, "DBMS_DATAPUMP is named outside a CALL in:\n\(sql)")
    }

    @Test("The block declares only scalar variables, no DBMS_DATAPUMP type or constant in PL/SQL")
    func noPlsqlLevelPackageReference() {
        let sql = oracleStatement()
        // The log-file type is written as its numeric value, not the SYS.DBMS_DATAPUMP.KU$_* constant a PL/SQL
        // reference would resolve through a shadow package.
        #expect(!sql.contains("KU$_FILE_TYPE_LOG_FILE"))
    }

    @Test("The table filter escapes a quote in the name through both literal levels")
    func tableFilterEscapesQuotes() {
        let sql = oracleStatement(table: "IT'S")
        #expect(sql.contains("IN (''IT''''S'')"))
    }

    @Test("A named schema is filtered without USER")
    func namedSchemaFilter() {
        let sql = oracleStatement(schema: "HR")
        #expect(sql.contains("IN (''HR'')"))
    }
}
