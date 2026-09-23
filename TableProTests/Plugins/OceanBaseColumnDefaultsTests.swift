//
//  OceanBaseColumnDefaultsTests.swift
//  TableProTests
//

import Testing

@Suite("OceanBase column defaults")
struct OceanBaseColumnDefaultsTests {
    private static let tableOptions = "ORGANIZATION INDEX DEFAULT CHARSET = utf8mb4 ROW_FORMAT = DYNAMIC "
        + "COMPRESSION = 'zstd_1.3.8' REPLICA_NUM = 1 BLOCK_SIZE = 16384 USE_BLOOM_FILTER = FALSE "
        + "ENABLE_MACRO_BLOCK_BLOOM_FILTER = FALSE TABLET_SIZE = 134217728 PCTFREE = 0"

    private static let expressionAndLiteral = #"""
    CREATE TABLE `t_dflt` (
      `id` int(11) NOT NULL,
      `e` varchar(36) DEFAULT (uuid()),
      `l` varchar(36) DEFAULT 'UUID()',
      `s` varchar(10) DEFAULT 'abc',
      `ts` timestamp NULL DEFAULT CURRENT_TIMESTAMP,
      `d` date DEFAULT (curdate()),
      `n` int(11) DEFAULT '5',
      PRIMARY KEY (`id`)
    ) \#(tableOptions)
    """#

    private static let awkwardLiterals = #"""
    CREATE TABLE `t` (
      `id` int(11) NOT NULL,
      `q` varchar(20) DEFAULT 'it\'s',
      `p` varchar(20) DEFAULT '(x)',
      `dq` varchar(30) DEFAULT 'DEFAULT \'a\', b',
      `nul` varchar(5) DEFAULT NULL,
      `bt` bit(1) DEFAULT b'1',
      `bin` varbinary(4) DEFAULT 'a',
      `ts3` datetime(3) DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
      `gen` int(11) GENERATED ALWAYS AS ((`id` + 1)) VIRTUAL,
      `cmt` int(11) DEFAULT '7' COMMENT 'DEFAULT (uuid()) here',
      `dec_col` decimal(5,2) DEFAULT '1.50',
      `js` json DEFAULT NULL,
      `lc` varchar(10) DEFAULT 'uuid()',
      `e2` varchar(40) DEFAULT (concat('a',',','b')),
      `nn` varchar(5) NOT NULL DEFAULT '',
      PRIMARY KEY (`id`)
    ) \#(tableOptions)
    """#

    private static let escapes = #"""
    CREATE TABLE `t` (
      `id` int(11) NOT NULL,
      `nl` varchar(20) DEFAULT 'a\nb' COMMENT 'line1\nline2',
      `tb` varchar(20) DEFAULT 'tab\there',
      `bs` varchar(20) DEFAULT 'back\\slash',
      `ex` varchar(40) DEFAULT (concat('it\'s','x')),
      `st` set('a','b'c') DEFAULT 'a',
      `ch` char(3) DEFAULT 'abc',
      PRIMARY KEY (`id`)
    ) \#(tableOptions)
    """#

    private static let partitionedWithEnum = #"""
    CREATE TABLE `p` (
      `id` int(11) NOT NULL,
      `kind` enum('a,b','c'd') DEFAULT 'c'd',
      `neg` int(11) DEFAULT '-1',
      `negd` decimal(6,2) DEFAULT '-1.50',
      `note` varchar(20) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT 'x' COMMENT 'has, comma',
      PRIMARY KEY (`id`)
    ) \#(tableOptions)
     partition by range(`id`)
    (partition `p0` values less than (100),
    partition `p1` values less than (MAXVALUE))
    """#

    private static let quotedNames = #"""
    CREATE TABLE `we``ird col` (
      `a``b` int(11) DEFAULT '1',
      `c d` varchar(5) DEFAULT 'x'
    ) \#(tableOptions)
    """#

    @Test("Each column's DEFAULT clause is read as written, and a column without one has none")
    func clausesAsWritten() throws {
        let clauses = try #require(MySQLCreateTableScanner.columnDefaultClauses(fromCreateTable: Self.awkwardLiterals))
        #expect(clauses["id"] == nil)
        #expect(clauses["gen"] == nil)
        #expect(clauses["q"] == #"'it\'s'"#)
        #expect(clauses["p"] == "'(x)'")
        #expect(clauses["dq"] == #"'DEFAULT \'a\', b'"#)
        #expect(clauses["nul"] == "NULL")
        #expect(clauses["bt"] == "b'1'")
        #expect(clauses["ts3"] == "CURRENT_TIMESTAMP(3)")
        #expect(clauses["cmt"] == "'7'")
        #expect(clauses["e2"] == "(concat('a',',','b'))")
        #expect(clauses["nn"] == "''")
    }

    @Test("An expression default and a literal with the same text resolve differently", arguments: [
        ("e", "uuid()", "(uuid())"),
        ("l", "UUID()", "'UUID()'"),
        ("s", "abc", "'abc'"),
        ("ts", "CURRENT_TIMESTAMP", "CURRENT_TIMESTAMP"),
        ("d", "curdate()", "(curdate())")
    ])
    func expressionOrLiteral(column: String, catalogDefault: String, expected: String) throws {
        let clauses = try #require(MySQLCreateTableScanner.columnDefaultClauses(fromCreateTable: Self.expressionAndLiteral))
        #expect(OceanBaseColumnDefaults.resolve(clause: clauses[column], catalogDefault: catalogDefault) == .value(expected))
    }

    @Test("Literals come back as the SQL the MySQL writer takes, whatever escapes OceanBase printed", arguments: [
        ("q", "it's", "'it''s'"),
        ("p", "(x)", "'(x)'"),
        ("dq", "DEFAULT 'a', b", "'DEFAULT ''a'', b'"),
        ("bin", "a", "'a'"),
        ("ts3", "CURRENT_TIMESTAMP(3)", "CURRENT_TIMESTAMP(3)"),
        ("lc", "uuid()", "'uuid()'"),
        ("e2", "concat('a',',','b')", "(concat('a',',','b'))"),
        ("nn", "", "''")
    ])
    func literalsAsSQL(column: String, catalogDefault: String, expected: String) throws {
        let clauses = try #require(MySQLCreateTableScanner.columnDefaultClauses(fromCreateTable: Self.awkwardLiterals))
        #expect(OceanBaseColumnDefaults.resolve(clause: clauses[column], catalogDefault: catalogDefault) == .value(expected))
    }

    @Test("Newlines, tabs, backslashes and quotes decode to the stored value", arguments: [
        ("nl", "a\nb", #"'a\nb'"#),
        ("tb", "tab\there", #"'tab\there'"#),
        ("bs", #"back\slash"#, #"'back\\slash'"#),
        ("ex", #"concat('it\'s','x')"#, #"(concat('it\'s','x'))"#),
        ("ch", "abc", "'abc'")
    ])
    func escapesDecode(column: String, catalogDefault: String, expected: String) throws {
        let clauses = try #require(MySQLCreateTableScanner.columnDefaultClauses(fromCreateTable: Self.escapes))
        #expect(OceanBaseColumnDefaults.resolve(clause: clauses[column], catalogDefault: catalogDefault) == .value(expected))
    }

    @Test("A set member printed with a bare quote does not disturb the columns after it")
    func malformedMemberListStaysOnItsLine() throws {
        let clauses = try #require(MySQLCreateTableScanner.columnDefaultClauses(fromCreateTable: Self.escapes))
        #expect(OceanBaseColumnDefaults.resolve(clause: clauses["ch"], catalogDefault: "abc") == .value("'abc'"))
        let partitioned = try #require(MySQLCreateTableScanner.columnDefaultClauses(fromCreateTable: Self.partitionedWithEnum))
        #expect(OceanBaseColumnDefaults.resolve(clause: partitioned["note"], catalogDefault: "x") == .value("'x'"))
        #expect(partitioned["p0"] == nil)
    }

    @Test("Backtick-escaped table and column names are read")
    func quotedNames() throws {
        let clauses = try #require(MySQLCreateTableScanner.columnDefaultClauses(fromCreateTable: Self.quotedNames))
        #expect(clauses["a`b"] == "'1'")
        #expect(OceanBaseColumnDefaults.resolve(clause: clauses["c d"], catalogDefault: "x") == .value("'x'"))
    }

    @Test("A clause that does not match the catalog is not trusted", arguments: [
        (String?.none, "abc"),
        (String?.some("NULL"), "abc"),
        (String?.some("'abd'"), "abc"),
        (String?.some("(uuid())"), "UUID()"),
        (String?.some("CURRENT_DATE"), "CURRENT_TIMESTAMP"),
        (String?.some("CURRENT_TIMESTAMP(3)"), "CURRENT_TIMESTAMP"),
        (String?.some("b'10'"), "b'1'")
    ])
    func mismatchIsUnverified(clause: String?, catalogDefault: String) {
        #expect(OceanBaseColumnDefaults.resolve(clause: clause, catalogDefault: catalogDefault) == .unverified)
    }

    @Test("A view's CREATE statement yields nothing to resolve against")
    func viewIsNotATable() {
        let view = "CREATE VIEW `v` AS select `tp_def2`.`p`.`id` AS `id`,`tp_def2`.`p`.`kind` AS `kind` from `tp_def2`.`p`"
        #expect(MySQLCreateTableScanner.columnDefaultClauses(fromCreateTable: view) == nil)
        let definer = "CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`%` SQL SECURITY DEFINER VIEW `v` AS select 1 AS `a`"
        #expect(MySQLCreateTableScanner.columnDefaultClauses(fromCreateTable: definer) == nil)
    }

    private static let unquotedIdentifiers = #"""
    CREATE TABLE t (
      id int(11) NOT NULL,
      a varchar(20) DEFAULT ((1 + 2)),
      b varchar(20) DEFAULT 'abc',
      c varchar(40) DEFAULT (now()),
      d varchar(20) DEFAULT '-1',
      g varbinary(4) DEFAULT 'A',
      key varchar(5) DEFAULT (upper('k')),
      `Mixed Case` varchar(5) DEFAULT (lower('M')),
      PRIMARY KEY (id)
    ) \#(tableOptions)
    """#

    @Test("A binary default, which OceanBase reports as text, comes back as a quoted literal")
    func binaryDefaultIsQuoted() {
        #expect(OceanBaseColumnDefaults.binaryLiteralDefault("A", dataType: "VARBINARY(4)") == "'A'")
        #expect(OceanBaseColumnDefaults.binaryLiteralDefault("it's", dataType: "BINARY(4)") == "'it''s'")
        #expect(OceanBaseColumnDefaults.binaryLiteralDefault("A", dataType: "VARCHAR(4)") == nil)
    }

    @Test("A catalog default with nothing to resolve against reads by OceanBase's rules, then MySQL's")
    func catalogDefaultWithoutCreateTable() {
        func read(_ value: String?, _ dataType: String, isNullable: Bool = true, extra: String = "") -> String? {
            OceanBaseColumnDefaults.columnDefault(value, extra: extra, dataType: dataType, isNullable: isNullable)
        }
        #expect(read("CURRENT_TIMESTAMP", "TIMESTAMP(3)") == "CURRENT_TIMESTAMP(3)")
        #expect(read("ab", "VARBINARY(4)") == "'ab'")
        #expect(read("abc", "VARCHAR(10)") == "'abc'")
        #expect(read("5", "INT(11)") == "5")
        #expect(read(nil, "VARCHAR(10)") == "NULL")
        #expect(read(nil, "VARCHAR(10)", isNullable: false) == nil)
        #expect(read(nil, "INT(11)", extra: "auto_increment") == nil)
    }

    @Test("A literal that does not close where the clause ends is not a literal", arguments: [
        #"'abc\'"#, "'(ab", "'a'b'", "'"
    ])
    func unterminatedLiteralIsUnverified(clause: String) {
        #expect(OceanBaseColumnDefaults.resolve(clause: clause, catalogDefault: "abc") == .unverified)
        #expect(OceanBaseColumnDefaults.resolve(clause: clause, catalogDefault: "(a") == .unverified)
    }

    @Test("A bare name may start with a digit, as sql_quote_show_create = 0 prints 1st_id")
    func bareNameStartingWithDigit() throws {
        let statement = "CREATE TABLE t (\n  id int(11) NOT NULL,\n  1st_id varchar(36) DEFAULT (uuid()),\n"
            + "  `$col` varchar(9) DEFAULT (upper('x')),\n  PRIMARY KEY (id)\n) ORGANIZATION INDEX"
        let clauses = try #require(MySQLCreateTableScanner.columnDefaultClauses(fromCreateTable: statement))
        #expect(clauses["1st_id"] == "(uuid())")
        #expect(clauses["$col"] == "(upper('x'))")
    }

    @Test("A bare CURRENT_TIMESTAMP in the catalog takes the column's own precision, the only one OceanBase accepts")
    func currentTimestampTakesColumnPrecision() {
        #expect(OceanBaseColumnDefaults.currentTimestampDefault("CURRENT_TIMESTAMP", dataType: "DATETIME(3)")
            == "CURRENT_TIMESTAMP(3)")
        #expect(OceanBaseColumnDefaults.currentTimestampDefault("CURRENT_TIMESTAMP", dataType: "TIMESTAMP(6)")
            == "CURRENT_TIMESTAMP(6)")
        #expect(OceanBaseColumnDefaults.currentTimestampDefault("CURRENT_TIMESTAMP", dataType: "DATETIME")
            == "CURRENT_TIMESTAMP")
        #expect(OceanBaseColumnDefaults.currentTimestampDefault("CURRENT_TIMESTAMP", dataType: "VARCHAR(40)") == nil)
        #expect(OceanBaseColumnDefaults.currentTimestampDefault("2020-01-01 00:00:00", dataType: "DATETIME") == nil)
    }

    private static let ansiQuotedIdentifiers = #"""
    CREATE TABLE "t" (
      "id" int(11) NOT NULL,
      "e" varchar(36) DEFAULT (uuid()),
      "l" varchar(20) DEFAULT 'it\'s (x)',
      "b" varchar(20) DEFAULT 'back\\slash (y)',
      "key" varchar(9) DEFAULT (upper('k')),
      "say ""hi""" varchar(9) DEFAULT (lower('H')),
      PRIMARY KEY ("id")
    ) \#(tableOptions)
    """#

    @Test("Identifiers in double quotes, as ANSI_QUOTES prints them, are read")
    func ansiQuotedIdentifiersAreRead() throws {
        let clauses = try #require(MySQLCreateTableScanner.columnDefaultClauses(fromCreateTable: Self.ansiQuotedIdentifiers))
        #expect(OceanBaseColumnDefaults.resolve(clause: clauses["e"], catalogDefault: "uuid()") == .value("(uuid())"))
        #expect(OceanBaseColumnDefaults.resolve(clause: clauses["l"], catalogDefault: "it's (x)") == .value("'it''s (x)'"))
        #expect(
            OceanBaseColumnDefaults.resolve(clause: clauses["b"], catalogDefault: #"back\slash (y)"#)
                == .value(#"'back\\slash (y)'"#)
        )
        #expect(clauses["key"] == "(upper('k'))")
        #expect(clauses[#"say "hi""#] == "(lower('H'))")
        #expect(clauses["PRIMARY"] == nil)
    }

    @Test("Identifiers printed without backticks, as sql_quote_show_create = 0 leaves them, are read")
    func unquotedIdentifiersAreRead() throws {
        let clauses = try #require(MySQLCreateTableScanner.columnDefaultClauses(fromCreateTable: Self.unquotedIdentifiers))
        #expect(OceanBaseColumnDefaults.resolve(clause: clauses["a"], catalogDefault: "(1 + 2)") == .value("((1 + 2))"))
        #expect(OceanBaseColumnDefaults.resolve(clause: clauses["c"], catalogDefault: "now()") == .value("(now())"))
        #expect(OceanBaseColumnDefaults.resolve(clause: clauses["g"], catalogDefault: "A") == .value("'A'"))
        #expect(OceanBaseColumnDefaults.resolve(clause: clauses["key"], catalogDefault: "upper('k')") == .value("(upper('k'))"))
        #expect(clauses["Mixed Case"] == "(lower('M'))")
        #expect(clauses["PRIMARY"] == nil)
    }

    @Test("Only a default the catalog cannot tell from a literal needs the CREATE statement", arguments: [
        ("VARCHAR(36)", "uuid()", true),
        ("VARCHAR(20)", "(1 + 2)", true),
        ("VARCHAR(10)", "(x)", true),
        ("DATE", "curdate()", true),
        ("JSON", "json_array()", true),
        ("VARBINARY(4)", "unhex('41')", true),
        ("VARBINARY(4)", "A", false),
        ("BINARY(1)", "a", false),
        ("TIMESTAMP(6)", "CURRENT_TIMESTAMP(6)", false),
        ("VARCHAR(20)", "abc", false),
        ("VARCHAR(20)", "-1", false),
        ("DATETIME(3)", "CURRENT_TIMESTAMP", false),
        ("DATE", "2020-01-01", false),
        ("INT(11)", "(1 + 2)", false),
        ("BIGINT UNSIGNED", "5", false),
        ("DECIMAL(5,2)", "1.50", false),
        ("BIT(1)", "b'1'", false),
        ("enum('a,b','c''d')", "c'd", false),
        ("set('a','b')", "a", false)
    ])
    func needsCreateTable(dataType: String, catalogDefault: String, expected: Bool) {
        #expect(OceanBaseColumnDefaults.catalogDefaultNeedsCreateTable(catalogDefault, dataType: dataType) == expected)
        #expect(!OceanBaseColumnDefaults.catalogDefaultNeedsCreateTable(nil, dataType: dataType))
    }

    @Test("A resolved default survives the MySQL column writer unchanged")
    func roundTripsThroughTheWriter() {
        #expect(mysqlDefaultValueLiteral("(uuid())", dataType: "VARCHAR(36)", isMariaDB: false) == "(uuid())")
        #expect(mysqlDefaultValueLiteral("'uuid()'", dataType: "VARCHAR(10)", isMariaDB: false) == "'uuid()'")
        #expect(mysqlDefaultValueLiteral("(curdate())", dataType: "DATE", isMariaDB: false) == "(curdate())")
        #expect(
            mysqlDefaultValueLiteral("CURRENT_TIMESTAMP(3)", dataType: "DATETIME(3)", isMariaDB: false)
                == "CURRENT_TIMESTAMP(3)"
        )
    }
}
