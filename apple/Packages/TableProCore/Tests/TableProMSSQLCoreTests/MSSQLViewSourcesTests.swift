import Foundation
@testable import TableProMSSQLCore
import Testing

// Every row below is what SQL Server 2022 (16.0.4305.5) returned for the query and view named beside it.
private enum Rows {
    // v: SELECT id, name, qty, req, qty + 1 AS q2, comp, ident FROM t; t also has a rowversion rv.
    static let browseV: [[String?]] = [
        ["id", "0", nil, "implc", "dbo", "t", "id", "1"],
        ["name", "0", nil, "implc", "dbo", "t", "name", "1"],
        ["qty", "0", nil, "implc", "dbo", "t", "qty", "1"],
        ["req", "0", nil, "implc", "dbo", "t", "req", "1"],
        ["q2", "0", nil, nil, nil, nil, nil, "0"],
        ["comp", "0", nil, "implc", "dbo", "t", "comp", "0"],
        ["ident", "0", nil, "implc", "dbo", "t", "ident", "0"],
        ["rv", "1", nil, "implc", "dbo", "t", "rv", "0"],
    ]

    // t (id PK, name NULL, qty NOT NULL DEFAULT 0, req NOT NULL, comp AS qty * 2, ident IDENTITY, rv rowversion)
    static let baseT: [[String?]] = [
        ["id", "0", nil, "0", "0", "0", "0", "1"],
        ["name", "1", nil, "0", "0", "0", "0", nil],
        ["qty", "0", "((0))", "1", "0", "0", "0", nil],
        ["req", "0", nil, "0", "0", "0", "0", nil],
        ["comp", "1", nil, "0", "0", "1", "0", nil],
        ["ident", "0", nil, "0", "1", "0", "0", nil],
        ["rv", "0", nil, "0", "0", "0", "1", nil],
    ]

    // v_join: SELECT t.id, t.name, t2.note FROM t JOIN t2 ON t2.t_id = t.id
    static let browseJoin: [[String?]] = [
        ["id", "0", nil, "implc", "dbo", "t", "id", "1"],
        ["name", "0", nil, "implc", "dbo", "t", "name", "1"],
        ["note", "0", nil, "implc", "dbo", "t2", "note", "1"],
        ["rv", "1", nil, "implc", "dbo", "t", "rv", "0"],
        ["id", "1", nil, "implc", "dbo", "t2", "id", "1"],
    ]

    // v_join_one: SELECT t.id, t.name FROM t JOIN t2 ON t2.t_id = t.id; only the hidden key names t2.
    static let browseJoinShowingOneTable: [[String?]] = [
        ["id", "0", nil, "implc", "dbo", "t", "id", "1"],
        ["name", "0", nil, "implc", "dbo", "t", "name", "1"],
        ["rv", "1", nil, "implc", "dbo", "t", "rv", "0"],
        ["id", "1", nil, "implc", "dbo", "t2", "id", "1"],
    ]

    // v_ck_partial: SELECT a, c FROM ck, where ck has PRIMARY KEY (b, a).
    static let browseKeyPartlyShown: [[String?]] = [
        ["a", "0", nil, "implc", "dbo", "ck", "a", "1"],
        ["c", "0", nil, "implc", "dbo", "ck", "c", "1"],
        ["b", "1", nil, "implc", "dbo", "ck", "b", "1"],
    ]

    static let baseCompositeKey: [[String?]] = [
        ["a", "0", nil, "0", "0", "0", "0", "2"],
        ["b", "0", nil, "0", "0", "0", "0", "1"],
        ["c", "1", nil, "0", "0", "0", "0", nil],
    ]

    // v_agg: SELECT name, count(*) AS n FROM t GROUP BY name
    static let browseAggregate: [[String?]] = [
        ["name", "0", nil, "implc", "dbo", "t", "name", "1"],
        ["n", "0", nil, nil, nil, nil, nil, "1"],
    ]

    // v_union: SELECT id, name FROM t UNION ALL SELECT id, name FROM t
    static let browseUnion: [[String?]] = [
        ["id", "0", nil, "implc", "dbo", "v_union", "id", "1"],
        ["name", "0", nil, "implc", "dbo", "v_union", "name", "1"],
    ]

    // v_twice: SELECT id, name, name AS name2, req FROM t
    static let browseColumnShownTwice: [[String?]] = [
        ["id", "0", nil, "implc", "dbo", "t", "id", "1"],
        ["name", "0", nil, "implc", "dbo", "t", "name", "1"],
        ["name2", "0", nil, "implc", "dbo", "t", "name", "1"],
        ["req", "0", nil, "implc", "dbo", "t", "req", "1"],
        ["rv", "1", nil, "implc", "dbo", "t", "rv", "0"],
    ]

    // v_cross: SELECT id, code, note FROM implc_arch.dbo.t
    static let browseOtherDatabase: [[String?]] = [
        ["id", "0", nil, "implc_arch", "dbo", "t", "id", "1"],
        ["code", "0", nil, "implc_arch", "dbo", "t", "code", "1"],
        ["note", "0", nil, "implc_arch", "dbo", "t", "note", "1"],
    ]

    // v_linked: SELECT id, code, note FROM implc_loop.implc_arch.dbo.t over a linked server.
    static let browseLinkedServer: [[String?]] = [
        ["id", "0", "implc_loop", "implc_arch", "dbo", "t", "id", "1"],
        ["code", "0", "implc_loop", "implc_arch", "dbo", "t", "code", "1"],
        ["note", "0", "implc_loop", "implc_arch", "dbo", "t", "note", "1"],
    ]

    // v_broken: its base table was dropped; the describe answers errors 208, 4413 and 11501.
    static let browseBroken: [[String?]] = [
        [nil, nil, nil, nil, nil, nil, nil, nil],
        [nil, nil, nil, nil, nil, nil, nil, nil],
        [nil, nil, nil, nil, nil, nil, nil, nil],
    ]

    // tmp: a system-versioned table with GENERATED ALWAYS period columns vf and vt.
    static let baseTemporal: [[String?]] = [
        ["id", "0", nil, "0", "0", "0", "0", "1"],
        ["name", "0", nil, "0", "0", "0", "0", nil],
        ["vf", "0", nil, "0", "0", "0", "1", nil],
        ["vt", "0", nil, "0", "0", "0", "1", nil],
    ]

    // heap: no primary key.
    static let baseHeap: [[String?]] = [
        ["a", "1", nil, "0", "0", "0", "0", nil],
        ["b", "1", nil, "0", "0", "0", "0", nil],
    ]

    // td.created NOT NULL DEFAULT SYSDATETIME(), read by sa and by a db_datareader without VIEW DEFINITION.
    static let baseDefaultReadable: [[String?]] = [
        ["id", "0", nil, "0", "0", "0", "0", "1"],
        ["name", "1", nil, "0", "0", "0", "0", nil],
        ["created", "0", "(sysdatetime())", "1", "0", "0", "0", nil],
    ]

    static let baseDefaultHidden: [[String?]] = [
        ["id", "0", nil, "0", "0", "0", "0", "1"],
        ["name", "1", nil, "0", "0", "0", "0", nil],
        ["created", "0", nil, "1", "0", "0", "0", nil],
    ]
}

private func table(_ database: String, _ name: String, server: String? = nil) -> MSSQLViewSources.BaseTable {
    MSSQLViewSources.BaseTable(server: server, database: database, schema: "dbo", name: name)
}

struct MSSQLViewSourcesTests {
    @Test("A view created WITH VIEW_METADATA hides its base table")
    func viewMetadataHidesBase() throws {
        let facts = try #require(MSSQLViewSources.ViewFacts(rows: [["1", "0"]]))
        #expect(facts.refusal == .baseTableHidden)
    }

    @Test("An enabled INSTEAD OF trigger on the view or a view under it makes writes run triggers")
    func insteadOfTrigger() throws {
        let facts = try #require(MSSQLViewSources.ViewFacts(rows: [["0", "1"]]))
        #expect(facts.refusal == .writesRunTriggers)
    }

    @Test("A plain view passes the catalog check, and a name that is no view answers nothing")
    func plainViewAndMissingView() throws {
        let facts = try #require(MSSQLViewSources.ViewFacts(rows: [["0", "0"]]))
        #expect(facts.refusal == nil)
        #expect(MSSQLViewSources.ViewFacts(rows: []) == nil)
    }

    @Test("Browse mode maps shown columns to base columns and leaves computed ones without one")
    func browseOneTable() {
        let browse = MSSQLViewSources.BrowseFacts(rows: Rows.browseV)
        #expect(browse.source == .table(table("implc", "t")))
        #expect(browse.columns == [
            .init(name: "id", baseColumn: "id", acceptsWrites: true),
            .init(name: "name", baseColumn: "name", acceptsWrites: true),
            .init(name: "qty", baseColumn: "qty", acceptsWrites: true),
            .init(name: "req", baseColumn: "req", acceptsWrites: true),
            .init(name: "q2", baseColumn: nil, acceptsWrites: false),
            .init(name: "comp", baseColumn: "comp", acceptsWrites: false),
            .init(name: "ident", baseColumn: "ident", acceptsWrites: false),
        ])
        #expect(browse.writableColumns == ["id", "name", "qty", "req"])
    }

    @Test("A join reads several tables")
    func browseJoin() {
        #expect(MSSQLViewSources.BrowseFacts(rows: Rows.browseJoin).source == .refused(.readsSeveralTables))
    }

    @Test("A hidden key column from another table counts that table too")
    func browseHiddenKeyOfAnotherTable() {
        let browse = MSSQLViewSources.BrowseFacts(rows: Rows.browseJoinShowingOneTable)
        #expect(browse.source == .refused(.readsSeveralTables))
        #expect(browse.columns.map { $0.name } == ["id", "name"])
    }

    @Test("A hidden key column of the same table is not shown and keeps one base table")
    func browseHiddenKeyOfSameTable() {
        let browse = MSSQLViewSources.BrowseFacts(rows: Rows.browseKeyPartlyShown)
        #expect(browse.source == .table(table("implc", "ck")))
        #expect(browse.columns.map { $0.name } == ["a", "c"])
    }

    @Test("A column with no source is never probed, even when browse mode calls it updatable")
    func browseAggregate() {
        let browse = MSSQLViewSources.BrowseFacts(rows: Rows.browseAggregate)
        #expect(browse.columns.last == MSSQLViewSources.ViewColumn(name: "n", baseColumn: nil, acceptsWrites: true))
        #expect(browse.writableColumns == ["name"])
    }

    @Test("A second column over one base column is not probed")
    func browseColumnShownTwice() {
        let browse = MSSQLViewSources.BrowseFacts(rows: Rows.browseColumnShownTwice)
        #expect(browse.writableColumns == ["id", "name", "req"])
        #expect(browse.columns.map { $0.name } == ["id", "name", "name2", "req"])
    }

    @Test("A base table in another database keeps that database")
    func browseOtherDatabase() {
        let browse = MSSQLViewSources.BrowseFacts(rows: Rows.browseOtherDatabase)
        #expect(browse.source == .table(table("implc_arch", "t")))
    }

    @Test("A base table on a linked server is hidden and its columns map to no base column")
    func browseLinkedServer() {
        let browse = MSSQLViewSources.BrowseFacts(rows: Rows.browseLinkedServer)
        #expect(browse.source == .refused(.baseTableHidden))
        #expect(browse.columns.allSatisfy { $0.baseColumn == nil })
        #expect(browse.writableColumns.isEmpty)
    }

    @Test("A view whose describe fails reads no table")
    func browseBroken() {
        let browse = MSSQLViewSources.BrowseFacts(rows: Rows.browseBroken)
        #expect(browse.source == .refused(.notUpdatable))
        #expect(browse.columns.isEmpty)
    }

    @Test("A UNION view names itself, so its probes decide")
    func browseUnionThenProbes() {
        let browse = MSSQLViewSources.BrowseFacts(rows: Rows.browseUnion)
        #expect(browse.source == .table(table("implc", "v_union")))
        let operations = MSSQLViewSources.allowedOperations(
            writableColumns: browse.writableColumns,
            probeRows: [
                ["delete", "4426"], ["delete", "11501"],
                ["update", "4406"], ["update", "11501"],
                ["insert", "4406"], ["insert", "11501"],
            ]
        )
        #expect(operations.isEmpty)
    }

    @Test("No probe error allows every operation")
    func probesClean() {
        let operations = MSSQLViewSources.allowedOperations(writableColumns: ["id"], probeRows: [])
        #expect(operations == [.update, .insert, .delete])
    }

    @Test("An aggregate view refuses every operation")
    func probesAggregate() {
        let operations = MSSQLViewSources.allowedOperations(
            writableColumns: ["name"],
            probeRows: [
                ["delete", "4403"], ["delete", "11501"],
                ["update", "4403"], ["update", "11501"],
                ["insert", "4403"], ["insert", "11501"],
            ]
        )
        #expect(operations.isEmpty)
    }

    @Test("A join refuses only the DELETE")
    func probesJoinDelete() {
        let operations = MSSQLViewSources.allowedOperations(
            writableColumns: ["id", "name"],
            probeRows: [["delete", "4405"], ["delete", "11501"]]
        )
        #expect(operations == [.update, .insert])
    }

    @Test(
        "A column-level compile error removes the operation",
        arguments: [271, 272, 264, 4_406, 8_102, 13_537]
    )
    func probesColumnError(errorNumber: Int) {
        let operations = MSSQLViewSources.allowedOperations(
            writableColumns: ["c"],
            probeRows: [["update", String(errorNumber)], ["update", "11501"]]
        )
        #expect(operations == [.insert, .delete])
    }

    @Test("A compile error not listed still refuses through 11501")
    func probesUnlistedCompileError() {
        let operations = MSSQLViewSources.allowedOperations(
            writableColumns: ["id"],
            probeRows: [["delete", "4413"], ["delete", "11501"]]
        )
        #expect(operations == [.update, .insert])
    }

    @Test("Missing permissions are left to the save, as for a table")
    func probesPermissionDenied() {
        let noDeleteOrInsert = MSSQLViewSources.allowedOperations(
            writableColumns: ["id", "name", "qty", "req"],
            probeRows: [["delete", "229"], ["delete", "11529"], ["insert", "229"], ["insert", "11529"]]
        )
        #expect(noDeleteOrInsert == [.update, .insert, .delete])
        let columnGrant = MSSQLViewSources.allowedOperations(
            writableColumns: ["id", "name"],
            probeRows: [["update", "230"], ["update", "11529"]]
        )
        #expect(columnGrant == [.update, .insert, .delete])
    }

    @Test("A base table trigger that uses a temp table blocks no operation")
    func probesTriggerTempTable() {
        let operations = MSSQLViewSources.allowedOperations(
            writableColumns: ["id"],
            probeRows: [["update", "11526"], ["delete", "11526"], ["insert", "11526"]]
        )
        #expect(operations == [.update, .insert, .delete])
    }

    @Test("With no writable column only DELETE is probed and allowed")
    func probesWithoutWritableColumn() {
        #expect(MSSQLViewSources.allowedOperations(writableColumns: [], probeRows: []) == [.delete])
        let query = MSSQLViewSources.probesQuery(schema: "dbo", view: "v", writableColumns: [])
        #expect(query.contains("('delete', N'DELETE FROM [dbo].[v] WHERE 1 = 0')"))
        #expect(!query.contains("UPDATE"))
        #expect(!query.contains("INSERT"))
    }

    @Test("Base columns carry the key in key order, defaults, and what the server fills")
    func baseColumns() throws {
        let base = try #require(MSSQLViewSources.BaseFacts(rows: Rows.baseT))
        #expect(base.keyColumns == ["id"])
        let byName = Dictionary(uniqueKeysWithValues: base.columns.map { ($0.name, $0) })
        let qty = try #require(byName["qty"])
        #expect(qty.defaultValue == "((0))")
        #expect(!qty.assignsValue && qty.acceptsWrites)
        let comp = try #require(byName["comp"])
        #expect(!comp.acceptsWrites && !comp.assignsValue)
        let ident = try #require(byName["ident"])
        #expect(ident.assignsValue && !ident.acceptsWrites)
        let rowversion = try #require(byName["rv"])
        #expect(rowversion.assignsValue && !rowversion.acceptsWrites)
        let req = try #require(byName["req"])
        #expect(!req.isNullable && req.defaultValue == nil && !req.assignsValue && req.acceptsWrites)
    }

    @Test("A composite key follows key_ordinal, not column order")
    func baseCompositeKey() throws {
        let base = try #require(MSSQLViewSources.BaseFacts(rows: Rows.baseCompositeKey))
        #expect(base.keyColumns == ["b", "a"])
    }

    @Test("A table without a primary key has no key columns")
    func baseHeap() throws {
        let base = try #require(MSSQLViewSources.BaseFacts(rows: Rows.baseHeap))
        #expect(base.keyColumns.isEmpty)
        #expect(base.columns.count == 2)
    }

    @Test("GENERATED ALWAYS period columns are filled by the server and refuse writes")
    func baseTemporal() throws {
        let base = try #require(MSSQLViewSources.BaseFacts(rows: Rows.baseTemporal))
        let period = base.columns.filter { $0.name == "vf" || $0.name == "vt" }
        #expect(period.count == 2)
        #expect(period.allSatisfy { $0.assignsValue && !$0.acceptsWrites })
    }

    @Test("A default whose text needs VIEW DEFINITION still fills the column")
    func baseHiddenDefault() throws {
        let readable = try #require(MSSQLViewSources.BaseFacts(rows: Rows.baseDefaultReadable))
        let shown = try #require(readable.columns.last)
        #expect(shown.defaultValue == "(sysdatetime())" && !shown.assignsValue)
        let hidden = try #require(MSSQLViewSources.BaseFacts(rows: Rows.baseDefaultHidden))
        let unread = try #require(hidden.columns.last)
        #expect(unread.defaultValue == nil && unread.hasDefault)
        #expect(unread.assignsValue && unread.acceptsWrites)
    }

    @Test("No base row means the user cannot see the base table")
    func baseHidden() {
        #expect(MSSQLViewSources.BaseFacts(rows: []) == nil)
    }

    @Test("The catalog query brackets the name and carries it as one Unicode literal")
    func viewFactsQueryQuoting() {
        let query = MSSQLViewSources.viewFactsQuery(schema: "s'q]x", view: "o'v]x")
        #expect(query.contains("DECLARE @view int = OBJECT_ID(N'[s''q]]x].[o''v]]x]');"))
        #expect(query.contains("tr.is_instead_of_trigger = 1 AND tr.is_disabled = 0"))
        #expect(query.contains("WHERE c.depth < 8"))
        #expect(query.contains("IF HAS_PERMS_BY_NAME(N'sys.sql_expression_dependencies', 'OBJECT', 'SELECT') = 1"))
    }

    @Test("The browse query describes SELECT * in mode 1")
    func browseQueryQuoting() {
        let query = MSSQLViewSources.browseQuery(schema: "s'q]x", view: "o'v]x")
        #expect(query.contains("sys.dm_exec_describe_first_result_set(N'SELECT * FROM [s''q]]x].[o''v]]x]', NULL, 1)"))
    }

    @Test("The probes bracket every name and escape it inside the literal")
    func probesQueryQuoting() {
        let query = MSSQLViewSources.probesQuery(schema: "s'q]x", view: "o'v]x", writableColumns: ["i'd", "n]m"])
        #expect(query.contains("('delete', N'DELETE FROM [s''q]]x].[o''v]]x] WHERE 1 = 0')"))
        #expect(query.contains("('update', N'UPDATE [s''q]]x].[o''v]]x] SET [i''d] = [i''d] WHERE 1 = 0')"))
        #expect(query.contains(
            "('insert', N'INSERT INTO [s''q]]x].[o''v]]x] ([i''d], [n]]m]) "
                + "SELECT [i''d], [n]]m] FROM [s''q]]x].[o''v]]x] WHERE 1 = 0')"
        ))
        #expect(query.contains("sys.dm_exec_describe_first_result_set(p.statement, NULL, 0)"))
    }

    @Test("The base query reads the base table's own database")
    func baseColumnsQueryQuoting() {
        let query = MSSQLViewSources.baseColumnsQuery(
            .init(database: "arch]ive", schema: "s'q]x", name: "t'b]l")
        )
        #expect(query.contains("FROM [arch]]ive].sys.columns c"))
        #expect(query.contains("JOIN [arch]]ive].sys.tables t"))
        #expect(query.contains("WHERE c.object_id = OBJECT_ID(N'[arch]]ive].[s''q]]x].[t''b]]l]')"))
        let current = MSSQLViewSources.baseColumnsQuery(.init(database: nil, schema: "dbo", name: "t"))
        #expect(current.contains("FROM sys.columns c"))
        #expect(current.contains("OBJECT_ID(N'[dbo].[t]')"))
    }
}
