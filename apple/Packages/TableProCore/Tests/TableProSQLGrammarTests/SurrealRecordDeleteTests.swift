import Foundation
import TableProSQLGrammar
import Testing

// Record id and DELETE forms from SurrealDB 2.3 and 3.0's parser (`parse_record_id_key`, `parse_delete_stmt`).
struct SurrealRecordDeleteTests {
    private static func deletesEveryRow(_ sql: String, _ engine: String = "SurrealDB") -> Bool {
        let readings = SQLLexicalReadings.resolve(databaseTypeId: engine, declared: nil, session: nil)
        return SQLStatementClassifier.deletesEveryRow(sql, databaseTypeId: engine, readings: readings)
    }

    @Test("A SurrealQL DELETE of one record by its id does not delete every row", arguments: [
        "DELETE person:tobie",
        "DELETE person:100",
        "delete person:tobie;",
        "DELETE ONLY person:tobie RETURN BEFORE",
        "DELETE FROM person:tobie",
        "DELETE person:-7",
        "DELETE person:+7",
        "DELETE person:⟨tobie smith⟩",
        "DELETE person:`8424486b-85b2-4448-ac8d-5d51083391c7`",
        "DELETE `Artykuł`:100",
        #"DELETE person:u"0190d7e0-5f2e-7b1c-9a3e-2f6d2c8b4a10""#,
        "DELETE weather:['London', d'2025-02-13T05:00:00Z']",
        "DELETE k:{ a: 1, b: [2, 3] }",
        "DELETE person:tobie TIMEOUT 5s",
        "DELETE person:tobie WITH NOINDEX",
        "DELETE person:tobie PARALLEL",
        "DELETE person:tobie EXPLAIN FULL",
        "/* one */ DELETE /* record */ person:tobie -- gone",
        "SELECT * FROM (DELETE person:tobie)",
    ])
    func oneRecordById(sql: String) {
        #expect(!Self.deletesEveryRow(sql))
    }

    @Test("A SurrealQL DELETE of a table, a range, a parameter, a query or several records deletes every row", arguments: [
        "DELETE person",
        "DELETE ONLY person",
        "DELETE person:1..10",
        "DELETE person:1..",
        "DELETE person:..",
        "DELETE person:..=5",
        "DELETE person:1>..5",
        "DELETE temperature:['London', NONE]..=['London', ..]",
        "DELETE person:['a', ..]",
        "DELETE $records",
        "DELETE (SELECT VALUE id FROM person WHERE age > 20 LIMIT 2)",
        "DELETE type::record('person', 1)",
        "DELETE person:tobie->bought",
        "DELETE person:tobie.friends",
        "DELETE person:tobie, person:jaime",
        "DELETE person:rand()",
        #"DELETE person:"tobie""#,
        #"DELETE r"person:tobie""#,
        "DELETE person: tobie",
        "DELETE person :tobie",
        "DELETE person:tobie RETURN DELETE person",
        "DELETE person:tobie; DELETE person",
        "SELECT * FROM (DELETE person)",
    ])
    func manyRecords(sql: String) {
        #expect(Self.deletesEveryRow(sql))
    }

    @Test("Only SurrealDB reads a record id, and a driver's row change is read as before")
    func otherEnginesReadAsBefore() {
        #expect(Self.deletesEveryRow("DELETE person:tobie", "MySQL"))
        let surrealQL = SQLLexicalReadings.resolve(databaseTypeId: "SurrealDB", declared: nil, session: nil).execution
        #expect(SQLUnfilteredWrite.writes(in: "DELETE person:tobie", grammar: surrealQL).first == .delete)
    }
}
