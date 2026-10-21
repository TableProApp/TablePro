//
//  SQLiteAttachedSchemaQueryTests.swift
//  TableProPluginKitTests
//

import Foundation
import TableProPluginKit
import Testing

struct SQLiteAttachedSchemaQueryTests {
    @Test("Nil, empty and main all name the opened file; anything else is an attached database")
    func attachedSchema() {
        #expect(SQLiteMasterQueries.attachedSchema(nil) == nil)
        #expect(SQLiteMasterQueries.attachedSchema("") == nil)
        #expect(SQLiteMasterQueries.attachedSchema("MAIN") == nil)
        #expect(SQLiteMasterQueries.attachedSchema("auth") == "auth")
    }

    @Test("An attached database's catalog and pragmas carry its quoted name")
    func qualifies() {
        #expect(SQLiteMasterQueries.catalogTable(schema: nil) == "sqlite_master")
        #expect(SQLiteMasterQueries.catalogTable(schema: #"we"ird"#) == #""we""ird".sqlite_master"#)
        #expect(SQLiteMasterQueries.pragmaSchemaArgument(nil).isEmpty)
        #expect(SQLiteMasterQueries.pragmaSchemaArgument("o'brien") == ", 'o''brien'")
        #expect(SQLiteMasterQueries.qualifiedTable("users", schema: "auth", quote: SQLiteMasterQueries.quoteIdentifier)
            == #""auth"."users""#)
        #expect(SQLiteMasterQueries.qualifiedTable("users", schema: nil, quote: SQLiteMasterQueries.quoteIdentifier)
            == #""users""#)
    }

    @Test("A quote followed by a combining mark is still doubled, so a name cannot end its quoting early")
    func quotingCountsCodeUnits() {
        let name = "a\"\u{301}b'\u{301}c"
        #expect(SQLiteMasterQueries.quoteIdentifier(name).unicodeScalars.filter { $0 == "\"" }.count == 4)
        #expect(SQLiteMasterQueries.escapeLiteral(name).unicodeScalars.filter { $0 == "'" }.count == 2)
    }

    @Test("The main database's queries are the ones the schema-less overloads always produced")
    func mainQueriesUnchanged() {
        #expect(SQLiteIndexCatalog.indexesQuery(table: "t") == SQLiteIndexCatalog.indexesQuery(table: "t", schema: nil))
        #expect(SQLiteIndexCatalog.schemaIndexesQuery == SQLiteIndexCatalog.schemaIndexesQuery(schema: "main"))
        #expect(SQLiteForeignKeyGrouping.foreignKeysQuery(table: "t")
            == SQLiteForeignKeyGrouping.foreignKeysQuery(table: "t", schema: nil))
        #expect(!SQLiteIndexCatalog.indexesQuery(table: "t").contains("\"main\""))
        #expect(SQLiteMasterQueries.triggerList(table: "t") == SQLiteMasterQueries.triggerList(table: "t", schema: nil, excludeNameGlob: nil))
    }

    @Test("Index, key and trigger reads for an attached table read that database only")
    func attachedReads() {
        let indexes = SQLiteIndexCatalog.indexesQuery(table: "users", schema: "auth")
        #expect(indexes.contains("pragma_index_list('users', 'auth')"))
        #expect(indexes.contains("pragma_index_xinfo(il.name, 'auth')"))
        #expect(indexes.contains(#""auth".sqlite_master"#))

        let keys = SQLiteForeignKeyGrouping.foreignKeysQuery(table: "sessions", schema: "auth")
        #expect(keys.contains("pragma_foreign_key_list('sessions', 'auth')"))
        #expect(keys.contains(#"pragma_table_info(p."table", 'auth')"#))
        #expect(keys.contains(#""auth".sqlite_master"#))

        #expect(SQLiteMasterQueries.triggerList(table: "users", schema: "auth", excludeNameGlob: nil)
            .contains(#"FROM "auth".sqlite_master"#))
    }

    @Test("A key read from an attached database points at its parent in that database")
    func keysCarryTheSchema() {
        let rows: [[PluginCellValue]] = [[
            .text("0"), .text("0"), .text("users"), .text("user_id"), .text("id"),
            .text("NO ACTION"), .text("CASCADE"), .text("NONE"),
            .text("CREATE TABLE sessions(user_id INTEGER REFERENCES users(id) ON DELETE CASCADE)")
        ]]
        let attached = SQLiteForeignKeyGrouping.foreignKeys(table: "sessions", schema: "auth", fromRows: rows)
        #expect(attached.count == 1)
        #expect(attached[0].referencedSchema == "auth")
        #expect(attached[0].referencedTable == "users")
        #expect(attached[0].onDelete == "CASCADE")

        let main = SQLiteForeignKeyGrouping.foreignKeys(table: "sessions", schema: nil, fromRows: rows)
        #expect(main[0].referencedSchema == nil)
    }

    @Test("A trigger read from an attached database names it as its schema")
    func triggerCarriesTheSchema() {
        let sql = "CREATE TRIGGER trg AFTER INSERT ON users BEGIN SELECT 1; END"
        #expect(SQLiteMasterQueries.trigger(name: "trg", table: "users", schema: "auth", sql: sql).schema == "auth")
        #expect(SQLiteMasterQueries.trigger(name: "trg", table: "users", sql: sql).schema == nil)
    }
}
