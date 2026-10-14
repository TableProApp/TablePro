import TableProPluginKit
import Testing

struct MySQLIndexKeyWriterTests {
    @Test("Expression keys are written in parentheses beside quoted and prefixed columns")
    func expressionKeysAreParenthesized() {
        let index = PluginIndexDefinition(
            name: "ix",
            columns: ["id", "coalesce(a, b)", "email"],
            indexType: "BTREE",
            columnPrefixes: ["email": 20],
            expressions: ["coalesce(a, b)"],
            includedColumns: nil,
            ddlMethodAndKeys: nil,
            ddlWhereClause: nil
        )
        #expect(mysqlIndexDefinitionSQL(index) == "INDEX `ix` (`id`, (coalesce(a, b)), `email`(20)) USING BTREE")
    }

    @Test("Only MySQL and MariaDB replace an index in one ALTER TABLE")
    func oneStatementModifyByFlavor() {
        let index = PluginIndexDefinition(name: "ix", columns: ["a"], indexType: "BTREE")
        #expect(
            mysqlModifyIndexSQL(table: "t", oldIndexName: "ix", newIndex: index, flavor: .mariadb)
                == "ALTER TABLE `t` DROP INDEX `ix`, ADD INDEX `ix` (`a`) USING BTREE"
        )
        #expect(mysqlModifyIndexSQL(table: "t", oldIndexName: "ix", newIndex: index, flavor: .tidb(version: nil)) == nil)
        #expect(
            mysqlModifyIndexSQL(table: "t", oldIndexName: "ix", newIndex: index, flavor: .oceanbase(version: nil)) == nil
        )
        #expect(mysqlModifyIndexSQL(table: "t", oldIndexName: "ix", newIndex: index, flavor: .databend) == nil)
    }

    /// Measured on MariaDB 13.0.2: `ADD INDEX PRIMARY (b)`, `ADD INDEX primary (b)` and
    /// `ADD INDEX Primary (b)` each fail with ERROR 1280, "Incorrect index name".
    @Test("An added index named PRIMARY in any case is refused, and a name that only starts with it is not")
    func primaryIsNotAnIndexName() {
        for name in ["PRIMARY", "primary", "Primary"] {
            #expect(mysqlReservedIndexNameRefusal(for: PluginIndexDefinition(name: name, columns: ["id"])) != nil)
        }
        #expect(mysqlReservedIndexNameRefusal(for: PluginIndexDefinition(name: "primary_email", columns: ["email"])) == nil)
    }
}
