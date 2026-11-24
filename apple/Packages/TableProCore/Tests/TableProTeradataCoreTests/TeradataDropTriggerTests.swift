import TableProTeradataCore
import Testing

struct TeradataDropTriggerTests {
    @Test("A trigger drop names the trigger in its database")
    func dropIsQualifiedByDatabase() {
        #expect(TeradataObjectQueries.dropTriggerStatement(name: "audit", database: "shop") == #"DROP TRIGGER "shop"."audit""#)
    }

    @Test("A trigger drop with no database names the trigger alone", arguments: [nil, ""] as [String?])
    func dropWithoutDatabase(database: String?) {
        #expect(TeradataObjectQueries.dropTriggerStatement(name: "audit", database: database) == #"DROP TRIGGER "audit""#)
    }

    @Test("A quote inside a name is doubled")
    func quoteInsideANameIsDoubled() {
        #expect(TeradataObjectQueries.dropTriggerStatement(name: #"a"b"#, database: #"d"b"#) == #"DROP TRIGGER "d""b"."a""b""#)
    }
}
