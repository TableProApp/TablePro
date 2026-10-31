import Foundation
import Testing

@testable import TableProMySQLCore

struct MySQLCreateTableOptionsTests {
    @Test("The options line reads the engine, counter, character set and collation")
    func readsTheOptionsLine() throws {
        let sql = """
            CREATE TABLE `orders` (
              `id` int NOT NULL AUTO_INCREMENT,
              `note` varchar(20) DEFAULT NULL,
              PRIMARY KEY (`id`)
            ) ENGINE=InnoDB AUTO_INCREMENT=42 DEFAULT CHARSET=latin1 COLLATE=latin1_bin
            """
        let options = try #require(MySQLCreateTableScanner.tableOptions(fromCreateTable: sql))
        #expect(options["ENGINE"] == "InnoDB")
        #expect(options["AUTO_INCREMENT"] == "42")
        #expect(options["CHARSET"] == "latin1")
        #expect(options["COLLATE"] == "latin1_bin")
    }

    @Test("A column comment or table comment holding an option is not read as one")
    func commentsAreNotOptions() throws {
        let sql = """
            CREATE TABLE `t` (
              `id` int NOT NULL AUTO_INCREMENT COMMENT ') AUTO_INCREMENT=7',
              PRIMARY KEY (`id`)
            ) ENGINE=InnoDB AUTO_INCREMENT=42 DEFAULT CHARSET=utf8mb4 COMMENT='x AUTO_INCREMENT=99'
            """
        let options = try #require(MySQLCreateTableScanner.tableOptions(fromCreateTable: sql))
        #expect(options["AUTO_INCREMENT"] == "42")
        #expect(options["COMMENT"] == "'x AUTO_INCREMENT=99'")
    }

    @Test("No AUTO_INCREMENT clause reads as no counter option")
    func clauseAbsentWhenNextValueIsOne() throws {
        let sql = """
            CREATE TABLE `t` (
              `id` int NOT NULL AUTO_INCREMENT,
              PRIMARY KEY (`id`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
            """
        let options = try #require(MySQLCreateTableScanner.tableOptions(fromCreateTable: sql))
        #expect(options["AUTO_INCREMENT"] == nil)
        #expect(options["ENGINE"] == "InnoDB")
    }

    @Test("Partition clauses on the following lines are not options")
    func partitionLinesAreSkipped() throws {
        let sql = """
            CREATE TABLE `p` (
              `id` int NOT NULL AUTO_INCREMENT,
              PRIMARY KEY (`id`)
            ) ENGINE=InnoDB AUTO_INCREMENT=100 DEFAULT CHARSET=utf8mb4
            /*!50100 PARTITION BY RANGE (`id`)
            (PARTITION p0 VALUES LESS THAN (10) ENGINE = InnoDB) */
            """
        let options = try #require(MySQLCreateTableScanner.tableOptions(fromCreateTable: sql))
        #expect(options["AUTO_INCREMENT"] == "100")
        #expect(options.count == 3)
    }

    @Test("MariaDB under NO_TABLE_OPTIONS prints a bare closing line, which holds no options")
    func noTableOptionsLine() throws {
        let sql = "CREATE TABLE \"t\" (\n  \"id\" int(11) NOT NULL,\n  PRIMARY KEY (\"id\")\n)"
        let options = try #require(MySQLCreateTableScanner.tableOptions(fromCreateTable: sql))
        #expect(options.isEmpty)
    }

    @Test("A view's statement is not a table's", arguments: [
        "CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`%` SQL SECURITY DEFINER VIEW `v` AS select 1 AS `1`",
        ""
    ])
    func viewHasNoOptions(sql: String) {
        #expect(MySQLCreateTableScanner.tableOptions(fromCreateTable: sql) == nil)
    }
}
