import Foundation
@testable import TableProMSSQLCore
import Testing

/// Rows are what SQL Server 2022 returns from `sys.dm_exec_describe_first_result_set` for the views named.
struct MSSQLViewSourcesTests {
    @Test("A view over one table maps each shown column to its base column, skipping computed ones")
    func oneTable() {
        let summary = MSSQLViewSources.summarize(rows: [
            ["key_id", "shop", "dbo", "t", "id"],
            ["name", "shop", "dbo", "t", "name"],
            ["q2", "shop", nil, nil, nil],
        ])
        #expect(summary.baseTables == [.init(database: "shop", schema: "dbo", name: "t")])
        #expect(summary.origins.map { $0.viewColumn } == ["key_id", "name"])
        #expect(summary.origins.map { $0.baseColumn } == ["id", "name"])
    }

    @Test("A join view names both tables and maps no column")
    func join() {
        let summary = MSSQLViewSources.summarize(rows: [
            ["id", "shop", "dbo", "t", "id"],
            ["tid", "shop", "dbo", "u", "tid"],
        ])
        #expect(summary.baseTables.count == 2)
        #expect(summary.origins.isEmpty)
    }

    @Test("The same table name in two databases is two tables")
    func sameNameInTwoDatabases() {
        let summary = MSSQLViewSources.summarize(rows: [
            ["id", "shop", "dbo", "t", "id"],
            ["code", "archive", "dbo", "t", "code"],
        ])
        #expect(summary.baseTables.count == 2)
    }

    @Test("A join counts as several tables even when it shows one table's columns")
    func joinShowingOneSide() {
        let summary = MSSQLViewSources.summarize(rows: [["id", "shop", "dbo", "t", "id"]])
        #expect(MSSQLViewSources.baseTableCount(summary, compileErrors: []) == 1)
        #expect(MSSQLViewSources.baseTableCount(summary, compileErrors: [4_405, 11_501]) == 2)
    }

    @Test("Only errors other than the multi-table one make a view not updatable")
    func compileErrors() {
        #expect(MSSQLViewSources.isUpdatable(compileErrors: []))
        #expect(MSSQLViewSources.isUpdatable(compileErrors: [4_405, 11_501]))
        #expect(!MSSQLViewSources.isUpdatable(compileErrors: [4_403, 11_501]))
    }

    @Test("The probes bracket the names and carry them as one Unicode literal")
    func queries() {
        let errors = MSSQLViewSources.compileErrorsQuery(schema: "dbo", view: "o'v]x")
        #expect(errors.contains("N'DELETE FROM [dbo].[o''v]]x] WHERE 1 = 0'"))
        let sources = MSSQLViewSources.columnSourcesQuery(schema: "dbo", view: "v")
        #expect(sources.contains("N'SELECT * FROM [dbo].[v]', NULL, 1"))
        #expect(sources.contains("is_hidden = 0 AND source_server IS NULL"))
        let key = MSSQLViewSources.primaryKeyQuery(.init(database: "arch]ive", schema: "dbo", name: "t"))
        #expect(key.contains("OBJECT_ID(N'[arch]]ive].[dbo].[t]')"))
        #expect(key.contains("FROM [arch]]ive].sys.indexes i"))
        #expect(key.contains("i.is_primary_key = 1"))
    }
}
