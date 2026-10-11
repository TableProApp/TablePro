import Foundation
import Testing

struct CassandraCommentStatementTests {
    @Test("A table comment is set through the table's comment option")
    func setsTableComment() {
        let sql = CassandraObjectQueries.tableCommentStatement(
            keyspace: "Shop", table: "orders", objectType: "TABLE", comment: "Customer's orders"
        )
        #expect(sql == #"ALTER TABLE "Shop"."orders" WITH comment = 'Customer''s orders'"#)
    }

    @Test("A nil or empty comment resets the option to an empty string")
    func clearsTableComment() {
        let cleared = #"ALTER TABLE "Shop"."orders" WITH comment = ''"#
        #expect(CassandraObjectQueries.tableCommentStatement(
            keyspace: "Shop", table: "orders", objectType: "TABLE", comment: nil
        ) == cleared)
        #expect(CassandraObjectQueries.tableCommentStatement(
            keyspace: "Shop", table: "orders", objectType: "TABLE", comment: ""
        ) == cleared)
    }

    @Test("Names are quoted with their own quotes doubled")
    func quotesNames() {
        let sql = CassandraObjectQueries.tableCommentStatement(
            keyspace: #"a"b"#, table: #"c"d"#, objectType: "TABLE", comment: "x"
        )
        #expect(sql == #"ALTER TABLE "a""b"."c""d" WITH comment = 'x'"#)
    }

    @Test("Only tables take a comment")
    func refusesOtherKinds() {
        for kind in ["VIEW", "MATERIALIZED VIEW", "SEQUENCE", "SYSTEM TABLE", "FOREIGN TABLE"] {
            #expect(CassandraObjectQueries.tableCommentStatement(
                keyspace: "s", table: "t", objectType: kind, comment: nil
            ) == nil)
        }
    }

    @Test("The comment is read from system_schema.tables with escaped literals")
    func readsCommentFromSystemSchema() {
        let sql = CassandraObjectQueries.tableComment(keyspace: "O'Shop", table: "orders")
        #expect(sql.contains("SELECT comment FROM system_schema.tables"))
        #expect(sql.contains("keyspace_name = 'O''Shop'"))
        #expect(sql.contains("table_name = 'orders'"))
    }

    @Test("An apostrophe followed by a combining mark is still doubled")
    func apostropheBeforeCombiningMark() {
        let sql = CassandraObjectQueries.tableCommentStatement(
            keyspace: "Shop", table: "orders", objectType: "TABLE", comment: "a'\u{0301}b"
        )
        #expect(sql == "ALTER TABLE \"Shop\".\"orders\" WITH comment = 'a''\u{0301}b'")
    }
}
