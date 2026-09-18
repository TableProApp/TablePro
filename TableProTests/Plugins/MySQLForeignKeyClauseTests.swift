//
//  MySQLForeignKeyClauseTests.swift
//  TableProTests
//
//  The foreign keys a `SHOW CREATE TABLE` statement carries, which is the only place a database
//  behind a MySQL proxy holds them.
//
//  Every fixture here is the verbatim output of a server, captured from the container named beside
//  it, so a change to the parser is measured against what a server really prints.
//

import Foundation
import TableProPluginKit
import Testing

@Suite("MySQL foreign key clause")
struct MySQLForeignKeyClauseTests {
    /// Verbatim `SHOW CREATE TABLE db1.t_child` on MySQL 8.4.11. MariaDB 11.4.13 prints the same
    /// clauses, differing only in `int(11)` and the table's collation.
    private let mysql84 = """
        CREATE TABLE `t_child` (
          `id` int NOT NULL,
          `p_id` int DEFAULT NULL,
          `p_tenant` int DEFAULT NULL,
          `remote_code` varchar(16) DEFAULT NULL,
          PRIMARY KEY (`id`),
          KEY `fk_child_parent` (`p_id`,`p_tenant`),
          KEY `fk_child_remote` (`remote_code`),
          CONSTRAINT `fk_child_parent` FOREIGN KEY (`p_id`, `p_tenant`) REFERENCES `t_parent` (`id`, `tenant`) \
        ON DELETE CASCADE ON UPDATE SET NULL,
          CONSTRAINT `fk_child_remote` FOREIGN KEY (`remote_code`) REFERENCES `db2`.`t_remote` (`code`) \
        ON DELETE SET NULL ON UPDATE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
        """

    /// The same table read back with `sql_mode='ANSI_QUOTES'`, verbatim from MySQL 8.4.11.
    private let ansiQuotes = """
        CREATE TABLE "t_child" (
          "id" int NOT NULL,
          "p_id" int DEFAULT NULL,
          "p_tenant" int DEFAULT NULL,
          "remote_code" varchar(16) DEFAULT NULL,
          PRIMARY KEY ("id"),
          KEY "fk_child_parent" ("p_id","p_tenant"),
          KEY "fk_child_remote" ("remote_code"),
          CONSTRAINT "fk_child_parent" FOREIGN KEY ("p_id", "p_tenant") REFERENCES "t_parent" ("id", "tenant") \
        ON DELETE CASCADE ON UPDATE SET NULL,
          CONSTRAINT "fk_child_remote" FOREIGN KEY ("remote_code") REFERENCES "db2"."t_remote" ("code") \
        ON DELETE SET NULL ON UPDATE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
        """

    private func parse(_ sql: String, omittedAction: String = "NO ACTION") -> [PluginForeignKeyInfo] {
        MySQLForeignKeyClause.parse(createTable: sql, database: "db1", omittedAction: omittedAction)
    }

    @Test("A composite key keeps its declaration order and pairs each column with its own")
    func compositeKeyOrder() {
        let keys = parse(mysql84).filter { $0.name == "fk_child_parent" }

        #expect(keys.map(\.column) == ["p_id", "p_tenant"])
        #expect(keys.map(\.referencedColumn) == ["id", "tenant"])
        #expect(keys.allSatisfy { $0.referencedTable == "t_parent" })
        #expect(keys.allSatisfy { $0.onDelete == "CASCADE" && $0.onUpdate == "SET NULL" })
    }

    /// The catalog names the referenced database on every row, so an unqualified clause has to be
    /// filled in with the database it was read from or a comparison reads it as having moved.
    @Test("An unqualified clause takes the queried database, a qualified one keeps its own")
    func referencedSchema() {
        let keys = parse(mysql84)

        #expect(keys.first { $0.name == "fk_child_parent" }?.referencedSchema == "db1")
        #expect(keys.first { $0.name == "fk_child_remote" }?.referencedSchema == "db2")
        #expect(keys.first { $0.name == "fk_child_remote" }?.referencedTable == "t_remote")
    }

    @Test("ANSI_QUOTES output parses to the same keys as the backtick rendering")
    func ansiQuotesRendering() {
        let backticks = parse(mysql84)
        let doubled = parse(ansiQuotes)

        #expect(doubled.map(\.name) == backticks.map(\.name))
        #expect(doubled.map(\.column) == backticks.map(\.column))
        #expect(doubled.map(\.referencedSchema) == backticks.map(\.referencedSchema))
        #expect(doubled.map(\.onUpdate) == backticks.map(\.onUpdate))
    }

    /// Measured on MySQL 5.5.62, 5.6.51, 5.7.44 and MariaDB 5.5.64 and 11.4.13: a clause with no
    /// action is reported `RESTRICT` by `REFERENTIAL_CONSTRAINTS`. MySQL 8.0.11, 8.0.16 and 8.4.11
    /// report `NO ACTION` for the same table.
    @Test("An omitted clause takes the spelling the server's own catalog would have answered")
    func omittedAction() {
        let ddl = """
            CREATE TABLE `t_plain` (
              `id` int(11) NOT NULL,
              `p_id` int(11) DEFAULT NULL,
              `p_tenant` int(11) DEFAULT NULL,
              PRIMARY KEY (`id`),
              KEY `fk_plain` (`p_id`,`p_tenant`),
              CONSTRAINT `fk_plain` FOREIGN KEY (`p_id`, `p_tenant`) REFERENCES `t_parent` (`id`, `tenant`)
            ) ENGINE=InnoDB DEFAULT CHARSET=latin1
            """

        let legacy = parse(ddl, omittedAction: "RESTRICT")
        #expect(legacy.allSatisfy { $0.onDelete == "RESTRICT" && $0.onUpdate == "RESTRICT" })

        let modern = parse(ddl, omittedAction: "NO ACTION")
        #expect(modern.allSatisfy { $0.onDelete == "NO ACTION" && $0.onUpdate == "NO ACTION" })
    }

    /// Verbatim from MySQL 5.7.44, which prints only the clause it was given.
    @Test("A half-named clause takes the default for the action it does not name")
    func oneActionNamed() {
        let ddl = """
            CREATE TABLE `t_delete_only` (
              `id` int(11) NOT NULL,
              CONSTRAINT `fk_delete_only` FOREIGN KEY (`p_id`) REFERENCES `t_parent` (`id`) ON DELETE CASCADE
            ) ENGINE=InnoDB
            """

        let keys = parse(ddl, omittedAction: "RESTRICT")
        #expect(keys.map(\.onDelete) == ["CASCADE"])
        #expect(keys.map(\.onUpdate) == ["RESTRICT"])
    }

    @Test("An unnamed key takes the index name beside it")
    func unnamedKeyTakesIndexName() {
        let keys = parse("CREATE TABLE `t` (`a` int, FOREIGN KEY `idx_a` (`a`) REFERENCES `p` (`id`))")

        #expect(keys.map(\.name) == ["idx_a"])
        #expect(keys.map(\.column) == ["a"])
    }

    /// A nameless key would reach a schema comparison as `DROP FOREIGN KEY` with nothing to name.
    /// No server measured emits one, so it is dropped rather than carried with an empty name.
    @Test("A key with no name at all is dropped")
    func namelessKeyDropped() {
        #expect(parse("CREATE TABLE `t` (`a` int, FOREIGN KEY (`a`) REFERENCES `p` (`id`))").isEmpty)
    }

    @Test("A backtick inside a name survives its escaping")
    func escapedName() {
        let keys = parse("CREATE TABLE `t` (CONSTRAINT `fk``x` FOREIGN KEY (`a``b`) REFERENCES `p` (`id`))")

        #expect(keys.map(\.name) == ["fk`x"])
        #expect(keys.map(\.column) == ["a`b"])
    }

    /// `SHOW CREATE TABLE` on a view answers with the view's `SELECT`, and the degraded read asks
    /// only base tables, so this has to come back empty rather than throwing.
    @Test("A CREATE VIEW body yields no keys")
    func viewBody() {
        let ddl = "CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `v_child` AS "
            + "select `t_plain`.`id` AS `id`,`t_plain`.`p_id` AS `p_id` from `t_plain`"

        #expect(parse(ddl).isEmpty)
    }

    @Test("A table with no constraint at all yields no keys")
    func noConstraints() {
        #expect(parse("CREATE TABLE `t` (`id` int NOT NULL, PRIMARY KEY (`id`))").isEmpty)
    }

    @Test("A CHECK constraint is not read as a foreign key")
    func checkConstraint() {
        #expect(parse("CREATE TABLE `t` (`a` int, CONSTRAINT `c` CHECK (`a` > 0))").isEmpty)
    }
}

@Suite("MySQL omitted foreign key action")
struct MySQLOmittedForeignKeyActionTests {
    /// Measured by declaring one two-column key with no action clause and reading
    /// `information_schema.REFERENTIAL_CONSTRAINTS` back.
    @Test("MySQL before 8.0 reports RESTRICT and 8.0 onwards reports NO ACTION")
    func mysqlBoundary() {
        #expect(MySQLServerVersion.omittedForeignKeyAction(banner: "5.5.62", flavor: .mysql) == "RESTRICT")
        #expect(MySQLServerVersion.omittedForeignKeyAction(banner: "5.6.51", flavor: .mysql) == "RESTRICT")
        #expect(MySQLServerVersion.omittedForeignKeyAction(banner: "5.7.44", flavor: .mysql) == "RESTRICT")
        #expect(MySQLServerVersion.omittedForeignKeyAction(banner: "8.0.11", flavor: .mysql) == "NO ACTION")
        #expect(MySQLServerVersion.omittedForeignKeyAction(banner: "8.0.16", flavor: .mysql) == "NO ACTION")
        #expect(MySQLServerVersion.omittedForeignKeyAction(banner: "8.4.11", flavor: .mysql) == "NO ACTION")
    }

    /// MariaDB never moved: 5.5.64 and 11.4.13 both answer RESTRICT, and its major numbers are past
    /// 8 so a version comparison alone would get it wrong.
    @Test("MariaDB reports RESTRICT at every version")
    func mariadbIsAlwaysRestrict() {
        #expect(MySQLServerVersion.omittedForeignKeyAction(banner: "5.5.64-MariaDB", flavor: .mariadb) == "RESTRICT")
        #expect(
            MySQLServerVersion.omittedForeignKeyAction(banner: "11.4.13-MariaDB-ubu2404", flavor: .mariadb)
                == "RESTRICT"
        )
    }

    @Test("An unreadable banner falls to the older spelling rather than guessing forward")
    func unknownBanner() {
        #expect(MySQLServerVersion.omittedForeignKeyAction(banner: nil, flavor: .mysql) == "RESTRICT")
    }
}
