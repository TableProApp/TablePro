//
//  SQLExportNationalLiteralTests.swift
//  FormatPluginTests
//

import Foundation
import TableProPluginKit
import Testing

// Measured on SQL Server 2022: '日本' into an nvarchar column restores as ??, N'日本' as 日本. db-lib reports that
// column as varchar, so every text literal is national.
struct SQLExportNationalLiteralTests {
    private func encoder(databaseTypeId: String) -> SQLExportRowValueEncoder {
        SQLExportRowValueEncoder(
            columns: ["n", "d", "i"],
            columnTypeNames: ["varchar", "date", "int"],
            excludedColumnNames: [],
            databaseTypeId: databaseTypeId,
            escapeStringLiteral: { $0.replacingOccurrences(of: "'", with: "''") }
        )
    }

    @Test("Every SQL Server text literal is N''; a number stays bare")
    func sqlServerTextIsNational() {
        let row = encoder(databaseTypeId: "SQL Server").render([.text("日本'"), .text("2026-10-20"), .text("7")])
        #expect(row == "  (N'日本''', N'2026-10-20', 7)")
    }

    @Test("Other engines keep the plain literal")
    func otherEnginesArePlain() {
        let row = encoder(databaseTypeId: "PostgreSQL").render([.text("日本"), .text("2026-10-20"), .text("7")])
        #expect(row == "  ('日本', '2026-10-20', 7)")
    }
}
