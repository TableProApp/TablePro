@testable import TableProMobile
import TableProModels
import Testing

struct MSSQLRowCapTests {
    @Test("A lone query ends on the server at the row cap", arguments: [
        "SELECT * FROM events",
        "SELECT * FROM events;",
        "WITH recent AS (SELECT * FROM events) SELECT * FROM recent",
        "-- newest first\nSELECT * FROM events ORDER BY id DESC",
    ])
    func loneQueryEndsAtCap(batch: String) {
        #expect(CappedRead.qualifies(batch, databaseType: .mssql))
    }

    @Test("A batch that may still write or run more reads past the row cap", arguments: [
        "SELECT * FROM events; UPDATE events SET seen = 1",
        "SELECT * FROM events UPDATE events SET seen = 1",
        "SELECT * FROM events; SELECT * FROM users",
        "SELECT * INTO #recent FROM events",
        "WITH old AS (SELECT * FROM events) DELETE FROM old",
        "DELETE FROM events OUTPUT deleted.id WHERE seen = 1",
        "SET NOCOUNT ON; SELECT * FROM events",
        "EXEC dbo.monthly_report",
    ])
    func batchReadsPastCap(batch: String) {
        #expect(!CappedRead.qualifies(batch, databaseType: .mssql))
    }
}
