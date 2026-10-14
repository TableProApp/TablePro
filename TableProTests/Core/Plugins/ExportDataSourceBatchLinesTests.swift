//
//  ExportDataSourceBatchLinesTests.swift
//  TableProTests
//
//  SQL Server's client runs a script in batches cut at lines holding only `GO`. The dump source tells
//  the SQL export which engines read one; FormatPluginTests' SQLExportBatchSeparatorTests holds the
//  export to writing them.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct ExportDataSourceBatchLinesTests {
    @Test("The dump source reports SQL Server's GO lines, and no other engine's")
    func adapterReportsBatchLines() {
        let sqlServer = ExportDataSourceAdapter(driver: MockDatabaseDriver(), databaseType: .mssql)
        let mysql = ExportDataSourceAdapter(driver: MockDatabaseDriver(), databaseType: .mysql)
        #expect(sqlServer.lexicalFeatures.contains(.batchSeparatorLines))
        #expect(!mysql.lexicalFeatures.contains(.batchSeparatorLines))
    }
}
