import TableProCassandraCore
import Testing

struct CassandraDropTriggerTests {
    @Test("A trigger drop names its table and skips a trigger that is gone")
    func dropNamesTheTable() {
        #expect(
            CassandraObjectQueries.dropTriggerStatement(name: "audit", keyspace: "shop", table: "orders")
                == #"DROP TRIGGER IF EXISTS "audit" ON "shop"."orders""#
        )
    }

    @Test("A quote inside a name is doubled")
    func quoteInsideANameIsDoubled() {
        #expect(
            CassandraObjectQueries.dropTriggerStatement(name: #"a"b"#, keyspace: #"k"s"#, table: #"t"1"#)
                == #"DROP TRIGGER IF EXISTS "a""b" ON "k""s"."t""1""#
        )
    }
}
