import Foundation
@testable import TableProMSSQLCore
import Testing

struct MSSQLTemporaryTableQueriesTests {
    @Test("A # name is read from tempdb, any other from the current database")
    func temporaryNames() {
        #expect(MSSQLSchemaQueries.namesTemporaryTable("#scratch"))
        #expect(MSSQLSchemaQueries.namesTemporaryTable("##shared"))
        #expect(!MSSQLSchemaQueries.namesTemporaryTable("orders"))
    }

    @Test("The object id resolves the session's own table through tempdb, with the name quoted as a literal")
    func objectIDQuotesTheName() {
        #expect(MSSQLSchemaQueries.temporaryObjectID("#we]ird'name") == "OBJECT_ID(N'tempdb..' + QUOTENAME(N'#we]ird''name'))")
    }

    @Test("The listing keeps local temporary tables only, matched back to this session through OBJECT_ID")
    func listingFiltersToTheSession() {
        let sql = MSSQLSchemaQueries.temporaryTables
        #expect(sql.contains("FROM tempdb.sys.tables AS t"))
        #expect(sql.contains("t.name LIKE N'#[^#]%' AND LEN(t.name) = 128"))
        #expect(sql.contains("WHERE OBJECT_ID(N'tempdb..' + QUOTENAME(LEFT(t.name, c.length))) = t.object_id"))
    }

    @Test("The temporary column read has the row shape parseColumnRow reads")
    func columnsShape() throws {
        let sql = MSSQLSchemaQueries.temporaryColumns(table: "#t")
        #expect(sql.contains("FROM tempdb.INFORMATION_SCHEMA.COLUMNS c"))
        #expect(sql.contains("OBJECT_NAME(OBJECT_ID(N'tempdb..' + QUOTENAME(N'#t')), DB_ID(N'tempdb'))"))
        #expect(!sql.contains("COLUMNPROPERTY"))

        let row = try #require(MSSQLSchemaQueries.parseColumnRow(
            ["x", "int", nil, "10", "0", "NO", nil, "1", "1", "0", "0"]
        ))
        #expect(row.isIdentity)
        #expect(row.isPrimaryKey)
        #expect(!row.isNullable)
    }

    @Test("The temporary index read takes tempdb's catalog")
    func indexesReadTempdb() {
        let sql = MSSQLSchemaQueries.temporaryIndexes(table: "#t")
        #expect(sql.contains("FROM tempdb.sys.indexes i"))
        #expect(sql.contains("WHERE i.object_id = OBJECT_ID(N'tempdb..' + QUOTENAME(N'#t'))"))
    }
}
