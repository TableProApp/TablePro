@testable import TableProMobile
import TableProMSSQLCore
import Testing

struct MSSQLCatalogDatabaseTests {
    @Test("A catalog read for a database runs through that database's sp_executesql, its quotes doubled")
    func runsInTheDatabase() {
        let statement = "SELECT name FROM sys.tables WHERE name = N'o''brien'"

        #expect(MSSQLDriver.catalogStatement(statement, in: "shop")
            == "EXEC [shop].sys.sp_executesql N'SELECT name FROM sys.tables WHERE name = N''o''''brien'''")
    }

    @Test("A closing bracket in the database name is doubled")
    func quotesTheDatabase() {
        #expect(MSSQLDriver.catalogStatement("SELECT 1", in: "shop]; DROP TABLE x --")
            == "EXEC [shop]]; DROP TABLE x --].sys.sp_executesql N'SELECT 1'")
    }

    @Test("No database, or an empty one, leaves the statement as it is")
    func noDatabaseLeavesTheStatement() {
        #expect(MSSQLDriver.catalogStatement("SELECT 1", in: nil) == "SELECT 1")
        #expect(MSSQLDriver.catalogStatement("SELECT 1", in: "") == "SELECT 1")
    }

    @Test("The database a window names wins, then the one the app last put the session in, then none")
    func catalogTargetOrder() {
        #expect(MSSQLDriver.catalogTarget(named: "shop", appDatabase: "staging") == "shop")
        #expect(MSSQLDriver.catalogTarget(named: nil, appDatabase: "staging") == "staging")
        #expect(MSSQLDriver.catalogTarget(named: "", appDatabase: "staging") == "staging")
        #expect(MSSQLDriver.catalogTarget(named: nil, appDatabase: nil) == nil)
    }

    @Test("Column, index and foreign key reads run whole inside the database, so OBJECT_ID resolves there")
    func tableReadsRunInTheDatabase() {
        let reads = [
            MSSQLSchemaQueries.columns(schema: "dbo", table: "orders"),
            MSSQLSchemaQueries.indexes(schema: "dbo", table: "orders"),
            MSSQLSchemaQueries.foreignKeys(schema: "dbo", table: "orders")
        ]

        for read in reads {
            #expect(MSSQLDriver.catalogStatement(read, in: "shop")
                == "EXEC [shop].sys.sp_executesql \(MSSQLStringLiteral.quoted(read))")
        }
    }
}
