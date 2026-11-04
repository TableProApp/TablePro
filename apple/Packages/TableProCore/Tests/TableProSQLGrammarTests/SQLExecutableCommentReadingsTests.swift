import Foundation
import TableProSQLGrammar
import Testing

struct SQLExecutableCommentReadingsTests {
    private static let mySQL = SQLLexicalReadings.resolve(
        databaseTypeId: "MySQL", declared: nil, session: nil
    ).execution

    private static let servers: [String: SQLExecutableCommentReadings.Server] = [
        "MySQL 8.0.46": .init(family: .mySQL5, version: 80_046),
        "MySQL 8.4.11": .init(family: .mySQL81, version: 80_411),
        "MariaDB 10.11.19": .init(family: .mariaDB, version: 101_119),
        "MariaDB 11.4.13": .init(family: .mariaDB, version: 110_413),
    ]

    private static func texts(_ sql: String, _ grammar: SQLLexicalGrammar = mySQL) -> [String] {
        SQLExecutableCommentReadings.texts(of: sql, grammar: grammar).map { Array($0) } ?? []
    }

    private static func dropsTable(_ text: String) -> Bool {
        SQLStatementScanner.executableStatements(in: text, grammar: mySQL).contains { statement in
            let code = SQLCodeProjection.code(of: statement.sql, grammar: mySQL)
            return code.range(of: #"DROP\s+TABLE\s+t\b"#, options: .regularExpression) != nil
        }
    }

    private static let every: Set<String> = ["MySQL 8.0.46", "MySQL 8.4.11", "MariaDB 10.11.19", "MariaDB 11.4.13"]

    // Each text was sent as one query to the four servers; the second value names the ones that dropped `t`.
    static let measured: [(String, Set<String>)] = [
        ("/*!99999 ' */ DROP TABLE t -- '", every),
        ("/*!50700 ' */ DROP TABLE t -- '", ["MariaDB 10.11.19", "MariaDB 11.4.13"]),
        ("/*!40101 ' */ DROP TABLE t -- '", []),
        ("/*!100000 ' */ DROP TABLE t -- '", ["MySQL 8.4.11"]),
        ("/*!800000 ' */ DROP TABLE t -- '", ["MySQL 8.4.11", "MariaDB 10.11.19", "MariaDB 11.4.13"]),
        ("/*!800000' */ DROP TABLE t -- '", ["MariaDB 10.11.19", "MariaDB 11.4.13"]),
        ("/*!8000000 ' */ DROP TABLE t -- '", ["MariaDB 10.11.19", "MariaDB 11.4.13"]),
        ("/*!80047 ' */ DROP TABLE t -- '", ["MySQL 8.0.46", "MariaDB 10.11.19", "MariaDB 11.4.13"]),
        ("/*!DROP TABLE t */", every),
        ("/*!99999 /* */ ' */ DROP TABLE t -- '", every),
        ("/*!99999 /* /* */ */ ' */ DROP TABLE t -- '", []),
        ("/*!99999 # ' */ DROP TABLE t -- '", every),
        ("/*!99999 ; */ DROP TABLE t", every),
        ("/*M! ' */ DROP TABLE t -- '", ["MySQL 8.0.46", "MySQL 8.4.11"]),
        ("/*M!999999 ' */ DROP TABLE t -- '", every),
        ("/*M!99999 ' */ DROP TABLE t -- '", ["MySQL 8.0.46", "MySQL 8.4.11"]),
        ("/*M! /* */ ' */ DROP TABLE t -- '", []),
        ("/*m! ' */ DROP TABLE t -- '", every),
        ("/*! /* ' */ DROP TABLE t */", every),
        ("/*! DROP TABLE t # */ '\n */", every),
        ("/*! DROP TABLE /*! t */", every),
        ("SELECT /*!50000 \"*/\", */ 1; /*!99999 ' */ DROP TABLE t -- '", every),
        ("SELECT /*!80000 \"*/\", */ 1; /*!80100 ' */ DROP TABLE t -- '", ["MySQL 8.0.46"]),
        ("SELECT 1--/*!99999 ' */1; DROP TABLE t -- '", every),
    ]

    @Test("Each server's text drops the table exactly when that server did", arguments: measured)
    func eachServerRunsWhatItRan(sql: String, droppedOn: Set<String>) {
        for (name, server) in Self.servers {
            let text = SQLExecutableCommentReadings.text(of: sql, grammar: Self.mySQL, on: server)
            #expect((text as NSString).length == (sql as NSString).length)
            #expect(Self.dropsTable(text) == droppedOn.contains(name), "\(name): \(sql)")
        }
    }

    @Test("A text a server drops a table from has a reading that drops it", arguments: measured)
    func everyDropHasAReading(sql: String, droppedOn: Set<String>) {
        let texts = Self.texts(sql)
        #expect(texts.first == sql)
        if !droppedOn.isEmpty {
            #expect(texts.contains(where: Self.dropsTable), "\(sql)")
        }
    }

    private static func statements(_ text: String) -> Set<String> {
        Set(SQLStatementScanner.executableStatements(in: text, grammar: mySQL).map(\.sql))
    }

    @Test(
        "Every statement any server runs is one the texts hold",
        arguments: measured.map(\.0) + [
            "/*!50000 DELETE FROM t */ /*!99999 WHERE 1=0 */",
            "/*!40101 SET NAMES utf8 */; /*!80016 DROP TABLE t */; SELECT /*!40001 SQL_NO_CACHE */ 1",
            "/*M!100301 DELETE FROM t */; /*!50700 DROP TABLE t */ ; /*!800000 TRUNCATE t */",
            "/*!40000 ALTER TABLE `t` DISABLE KEYS */;\nINSERT INTO t VALUES (1, 'case');\n/*!40000 ALTER TABLE `t` ENABLE KEYS */;",
            "CREATE PROCEDURE p() 1BEGIN /*!50000 DELETE FROM t */; /*!99999 DROP TABLE t */; END",
            "/*T! DROP TABLE t */; /*T![clustered_index] SELECT 1 */; SELECT 1--/*!99999 x */1",
            "CREATE PROCEDURE p() \u{E9}BEGIN /*!50000 DELETE FROM t */; /*!99999 DROP TABLE t */; END",
        ]
    )
    func textsHoldEveryServersStatements(sql: String) {
        let held = Self.texts(sql).reduce(into: Set<String>()) {
            $0.formUnion(Self.statements($1))
        }
        let versions = [0, 40_000, 40_001, 40_101, 50_000, 50_700, 80_016, 80_046, 80_100, 80_411, 99_999, 100_301]
            + [101_119, 110_413, 999_999]
        for family in SQLExecutableCommentReadings.Family.allCases {
            for version in versions {
                let server = SQLExecutableCommentReadings.Server(family: family, version: version)
                let ran = Self.statements(SQLExecutableCommentReadings.text(of: sql, grammar: Self.mySQL, on: server))
                #expect(ran.isSubset(of: held), "\(family) \(version): \(sql)")
            }
        }
    }

    @Test("A mixed text is read under every threshold its versions set")
    func mixedThresholdsAreEachRead() {
        let sql = "SELECT /*!50000 \"*/\", */ 1; /*!99999 ' */ DROP TABLE t -- '"
        let texts = Self.texts(sql)
        #expect(texts.contains(where: Self.dropsTable))
        #expect(!Self.dropsTable(SQLExecutableCommentReadings.text(
            of: sql, grammar: Self.mySQL, on: .init(family: .mySQL5, version: 0)
        )))
        #expect(!Self.dropsTable(SQLExecutableCommentReadings.text(
            of: sql, grammar: Self.mySQL, on: .init(family: .mySQL81, version: 99_999)
        )))
    }

    // Measured on TiDB 8.5.1: each of these dropped `t`.
    @Test("A DROP TiDB runs has a reading that shows it", arguments: [
        "/*T! DROP TABLE t */",
        "/*T![clustered_index] DROP TABLE t */",
        "/*T![no_such_feature] ' */ DROP TABLE t -- '",
        "/*!99999 DROP TABLE t */",
        "/*M! ' */ DROP TABLE t -- '",
    ])
    func tiDBDropsHaveAReading(sql: String) {
        #expect(Self.texts(sql).contains(where: Self.dropsTable))
    }

    @Test("TiDB runs /*T! and every /*!, whatever its version")
    func tiDBRunsItsOwnComments() {
        let tiDB = SQLExecutableCommentReadings.Server(family: .tiDB, version: 0)
        #expect(Self.dropsTable(SQLExecutableCommentReadings.text(of: "/*T! DROP TABLE t */", grammar: Self.mySQL, on: tiDB)))
        #expect(!Self.dropsTable(SQLExecutableCommentReadings.text(
            of: "/*!99999 ' */ DROP TABLE t -- '", grammar: Self.mySQL, on: tiDB
        )))
    }

    @Test("A Galera node runs /*!99997, which every other MariaDB skips")
    func galeraRunsItsOwnVersion() {
        let sql = "/*!99997 DROP TABLE t */"
        let mariaDB = SQLExecutableCommentReadings.Server(family: .mariaDB, version: 110_413)
        let galera = SQLExecutableCommentReadings.Server(family: .galera, version: 110_413)
        #expect(!Self.dropsTable(SQLExecutableCommentReadings.text(of: sql, grammar: Self.mySQL, on: mariaDB)))
        #expect(Self.dropsTable(SQLExecutableCommentReadings.text(of: sql, grammar: Self.mySQL, on: galera)))
    }

    @Test("A MySQL Galera node runs /*!99997 and still skips the versions between its own and that one")
    func mySQLGaleraRunsItsOwnVersion() {
        let sql = "/*!50700 # */ \"\n*/ /*!90000 ' */ /*!99997 DROP TABLE t # */ ' \"\n*/"
        let nodes: [(SQLExecutableCommentReadings.Family, SQLExecutableCommentReadings.Family, Int)] = [
            (.mySQL5, .mySQL5Galera, 80_036), (.mySQL81, .mySQL81Galera, 80_403),
        ]
        for (family, galeraFamily, version) in nodes {
            let mySQL = SQLExecutableCommentReadings.Server(family: family, version: version)
            let galera = SQLExecutableCommentReadings.Server(family: galeraFamily, version: version)
            #expect(!Self.dropsTable(SQLExecutableCommentReadings.text(of: sql, grammar: Self.mySQL, on: mySQL)))
            #expect(Self.dropsTable(SQLExecutableCommentReadings.text(of: sql, grammar: Self.mySQL, on: galera)))
        }
        #expect(Self.texts(sql).contains(where: Self.dropsTable))
    }

    @Test(
        "A text with no executable comment, or a grammar that reads none, is read once",
        arguments: ["SELECT 1", "SELECT '/*!99999 x */'", "/*m! x */ SELECT 1", "SELECT 1 -- /*!99999"]
    )
    func plainTextIsReadOnce(sql: String) {
        #expect(Self.texts(sql) == [sql])
        #expect(Self.texts(sql, .ansi) == [sql])
    }

    @Test("A text that sets more versions than a gate reads has no texts, so the gate answers its worst case")
    func tooManyVersionsAreNotRead() {
        let many = (0..<40).map { "/*!\(50_000 + $0) x */" }.joined(separator: " ")
        let quoted = (0..<40).map { "'/*!\(50_000 + $0) x */'" }.joined(separator: ", ")
        #expect(SQLExecutableCommentReadings.texts(of: "SELECT 1 \(many)", grammar: Self.mySQL) == nil)
        #expect(SQLExecutableCommentReadings.texts(of: "SELECT \(quoted)", grammar: Self.mySQL) == nil)
        let few = (0..<SQLExecutableCommentReadings.maximumVersions).map { "/*!\(50_000 + $0) x */" }
        #expect(SQLExecutableCommentReadings.texts(of: few.joined(separator: " "), grammar: Self.mySQL) != nil)
    }

    @Test("Only an opener the grammar reads as code holds an executable comment")
    func holdsOnlyRealOpeners() {
        func holds(_ sql: String, _ grammar: SQLLexicalGrammar = Self.mySQL) -> Bool {
            SQLExecutableCommentReadings.holdsExecutableComment(sql, grammar: grammar)
        }
        #expect(holds("SELECT /*!40001 SQL_NO_CACHE */ 1"))
        #expect(holds("/*M!100301 SET @x = 1 */"))
        #expect(!holds("/*m! SET @x = 1 */"))
        #expect(!holds("SELECT '/*!40101 x */'"))
        #expect(!holds("SELECT /*!40101 x */", .ansi))
    }
}
