import Foundation
import TableProMSSQLCore
import Testing

struct MSSQLTypeQueriesTests {
    @Test("The type list filters on the schema as an N literal and keys each type by user_type_id")
    func typeListFiltersOnSchema() {
        let sql = MSSQLTypeQueries.userDefinedTypeList(schema: "o'neil")
        #expect(sql.contains("WHERE t.is_user_defined = 1 AND s.name = N'o''neil'"))
        #expect(sql.contains("CONVERT(varchar(11), t.user_type_id) AS identity_id"))
        #expect(sql.contains("ORDER BY t.name"))
    }

    @Test("The type list names its kind in the spellings Kind reads")
    func typeListKindSpellings() {
        let sql = MSSQLTypeQueries.userDefinedTypeList(schema: "dbo")
        for kind in [MSSQLTypeQueries.Kind.alias, .table, .clr] {
            #expect(sql.contains("'\(kind.rawValue)'"))
        }
        #expect(MSSQLTypeQueries.Kind(rawValue: "TABLE") == .table)
    }

    @Test("A unicode base type's byte length is halved back to characters")
    func baseTypeHalvesUnicodeLength() {
        let sql = MSSQLTypeQueries.userDefinedTypeList(schema: "dbo")
        #expect(sql.contains("CONVERT(varchar(11), t.max_length / 2)"))
    }

    @Test("Each table type read filters on the schema and the type name", arguments: [
        MSSQLTypeQueries.tableTypeColumns(schema: "dbo", name: "Id]List"),
        MSSQLTypeQueries.tableTypeIndexes(schema: "dbo", name: "Id]List"),
        MSSQLTypeQueries.tableTypeCheckConstraints(schema: "dbo", name: "Id]List"),
    ])
    func tableTypeReadsFilterOnNames(sql: String) {
        #expect(sql.contains("AND s.name = N'dbo'"))
        #expect(sql.contains("AND tt.name = N'Id]List'"))
    }

    @Test("Index rows come one per key column in key order, included columns left out")
    func tableTypeIndexesOnePerKey() {
        let sql = MSSQLTypeQueries.tableTypeIndexes(schema: "dbo", name: "T")
        #expect(sql.contains("AND ic.is_included_column = 0"))
        #expect(sql.contains("ORDER BY i.index_id, ic.key_ordinal"))
    }

    @Test("The database collation is read for the current database")
    func databaseCollationReadsCurrentDatabase() {
        #expect(MSSQLTypeQueries.databaseCollation
            == "SELECT CONVERT(varchar(128), DATABASEPROPERTYEX(DB_NAME(), 'Collation'))")
    }
}
