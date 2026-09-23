//
//  MySQLColumnDefinitionSQLTests.swift
//  TableProTests
//
//  MySQL restates a column in full for MODIFY/CHANGE COLUMN, so every attribute the
//  clause builder omits is dropped by the server. These cover the attributes that a
//  round trip has to carry through an edit to an unrelated field.
//

import TableProPluginKit
import Testing

@Suite("MySQL Column Definition SQL")
struct MySQLColumnDefinitionSQLTests {
    private func timestampColumn(
        dataType: String = "TIMESTAMP",
        defaultValue: String? = nil,
        onUpdate: String? = nil,
        comment: String? = nil
    ) -> PluginColumnDefinition {
        PluginColumnDefinition(
            name: "updated_at",
            dataType: dataType,
            isNullable: false,
            defaultValue: defaultValue,
            comment: comment,
            onUpdate: onUpdate
        )
    }

    // MARK: - On Update

    @Test("On update renders for a timestamp column")
    func onUpdateRenders() {
        let sql = mysqlColumnDefinitionSQL(
            timestampColumn(defaultValue: "CURRENT_TIMESTAMP", onUpdate: "CURRENT_TIMESTAMP")
        )
        #expect(sql.contains("DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP"))
    }

    @Test("On update adopts the column's fractional-second precision")
    func onUpdateDerivesPrecision() {
        let sql = mysqlColumnDefinitionSQL(
            timestampColumn(dataType: "TIMESTAMP(6)", onUpdate: "CURRENT_TIMESTAMP")
        )
        #expect(sql.contains("ON UPDATE CURRENT_TIMESTAMP(6)"))
    }

    @Test("On update precision is re-derived rather than trusted")
    func onUpdateOverridesStalePrecision() {
        let sql = mysqlColumnDefinitionSQL(
            timestampColumn(dataType: "DATETIME(3)", onUpdate: "CURRENT_TIMESTAMP(6)")
        )
        #expect(sql.contains("ON UPDATE CURRENT_TIMESTAMP(3)"))
        #expect(!sql.contains("CURRENT_TIMESTAMP(6)"))
    }

    @Test("An expression outside the whitelist is omitted, never emitted raw")
    func onUpdateRejectsUnknownExpression() {
        let sql = mysqlColumnDefinitionSQL(timestampColumn(onUpdate: "NOW()"))
        #expect(!sql.contains("ON UPDATE"))
        #expect(!sql.contains("NOW()"))
    }

    @Test("No on update attribute emits no clause")
    func onUpdateAbsent() {
        let sql = mysqlColumnDefinitionSQL(timestampColumn(defaultValue: "CURRENT_TIMESTAMP"))
        #expect(!sql.contains("ON UPDATE"))
    }

    @Test("Editing an unrelated attribute keeps the on update clause")
    func onUpdateSurvivesCommentEdit() {
        let sql = mysqlColumnDefinitionSQL(
            timestampColumn(
                defaultValue: "CURRENT_TIMESTAMP", onUpdate: "CURRENT_TIMESTAMP", comment: "touched"
            )
        )
        #expect(sql.contains("ON UPDATE CURRENT_TIMESTAMP"))
        #expect(sql.contains("COMMENT 'touched'"))
    }

    // MARK: - Default Value

    @Test("A fractional-second default is an expression, not a quoted literal")
    func fractionalDefaultIsNotQuoted() {
        let sql = mysqlColumnDefinitionSQL(
            timestampColumn(dataType: "TIMESTAMP(6)", defaultValue: "CURRENT_TIMESTAMP(6)")
        )
        #expect(sql.contains("DEFAULT CURRENT_TIMESTAMP(6)"))
        #expect(!sql.contains("'CURRENT_TIMESTAMP"))
    }

    @Test("A bare CURRENT_TIMESTAMP default is unquoted")
    func bareDefaultIsNotQuoted() {
        let sql = mysqlColumnDefinitionSQL(timestampColumn(defaultValue: "CURRENT_TIMESTAMP"))
        #expect(sql.contains("DEFAULT CURRENT_TIMESTAMP"))
        #expect(!sql.contains("'CURRENT_TIMESTAMP'"))
    }

    @Test("A quoted literal default is emitted as written")
    func quotedLiteralPassesThrough() {
        let column = PluginColumnDefinition(
            name: "status", dataType: "VARCHAR(16)", isNullable: false, defaultValue: "'it''s active'"
        )
        #expect(mysqlColumnDefinitionSQL(column).contains("DEFAULT 'it''s active'"))
    }

    @Test("An expression default is emitted as written rather than quoted")
    func expressionDefaultIsNotQuoted() {
        let column = PluginColumnDefinition(
            name: "id", dataType: "VARCHAR(36)", isNullable: false, defaultValue: "(UUID())"
        )
        let sql = mysqlColumnDefinitionSQL(column)
        #expect(sql.contains("DEFAULT (UUID())"))
        #expect(!sql.contains("'(UUID())'"))
    }

    /// MySQL requires parentheses around an expression default from 8.0.13; MariaDB takes them
    /// either way and writes them bare itself. Copying a MariaDB table to MySQL is what turned an
    /// unparenthesised `uuid()` into a statement the server rejects.
    @Test(
        "An expression default is parenthesised for MySQL and left bare for MariaDB",
        arguments: [
            (value: "uuid()", type: "CHAR(36)", mysql: "(uuid())", mariadb: "uuid()"),
            (value: "curdate()", type: "DATE", mysql: "(curdate())", mariadb: "curdate()"),
            (value: "(UUID())", type: "CHAR(36)", mysql: "(UUID())", mariadb: "(UUID())"),
            (value: "'abc'", type: "VARCHAR(8)", mysql: "'abc'", mariadb: "'abc'"),
            (value: "0", type: "INT", mysql: "0", mariadb: "0"),
            (value: "-1.5", type: "DECIMAL(4,1)", mysql: "-1.5", mariadb: "-1.5"),
            (value: "NULL", type: "INT", mysql: "NULL", mariadb: "NULL"),
            (value: "b'1'", type: "BIT(1)", mysql: "b'1'", mariadb: "b'1'"),
            (value: "0x61", type: "VARBINARY(8)", mysql: "0x61", mariadb: "0x61")
        ]
    )
    func expressionsAreParenthesisedForMySQLOnly(value: String, type: String, mysql: String, mariadb: String) {
        #expect(mysqlDefaultValueLiteral(value, dataType: type, isMariaDB: false) == mysql, "\(value)")
        #expect(mysqlDefaultValueLiteral(value, dataType: type, isMariaDB: true) == mariadb, "\(value)")
    }

    /// The one expression MySQL insists on bare, and only on the types that can carry it.
    @Test("CURRENT_TIMESTAMP stays bare on a temporal column and is parenthesised elsewhere")
    func currentTimestampParenthesisation() {
        #expect(mysqlDefaultValueLiteral("CURRENT_TIMESTAMP", dataType: "TIMESTAMP", isMariaDB: false)
            == "CURRENT_TIMESTAMP")
        #expect(mysqlDefaultValueLiteral("CURRENT_TIMESTAMP", dataType: "DATETIME(6)", isMariaDB: false)
            == "CURRENT_TIMESTAMP(6)")
        #expect(mysqlDefaultValueLiteral("CURRENT_TIMESTAMP", dataType: "VARCHAR(32)", isMariaDB: false)
            == "(CURRENT_TIMESTAMP)")
    }

    @Test(
        "A type that cannot carry a bare default is given the parentheses the grammar needs",
        arguments: [
            (dataType: "TEXT", value: "''", expected: "DEFAULT ('')"),
            (dataType: "LONGBLOB", value: "''", expected: "DEFAULT ('')"),
            (dataType: "JSON", value: "'{}'", expected: "DEFAULT ('{}')"),
            (dataType: "GEOMETRY", value: "ST_GeomFromText('POINT(0 0)')",
             expected: "DEFAULT (ST_GeomFromText('POINT(0 0)'))"),
            (dataType: "TEXT", value: "(UUID())", expected: "DEFAULT (UUID())"),
            (dataType: "VARCHAR(16)", value: "''", expected: "DEFAULT ''")
        ]
    )
    func parenthesisedWhereRequired(dataType: String, value: String, expected: String) {
        let column = PluginColumnDefinition(
            name: "payload", dataType: dataType, isNullable: true, defaultValue: value
        )
        #expect(mysqlColumnDefinitionSQL(column).contains(expected))
    }

    // MARK: - Catalog Round Trip

    @Test(
        "A MySQL catalog default becomes the SQL that recreates it",
        arguments: [
            (value: "abc", extra: "", type: "VARCHAR(16)", expected: "'abc'"),
            (value: "", extra: "", type: "VARCHAR(16)", expected: "''"),
            (value: "it's", extra: "", type: "VARCHAR(16)", expected: "'it''s'"),
            (value: "0", extra: "", type: "INT", expected: "0"),
            (value: "-1.5", extra: "", type: "DECIMAL(4,1)", expected: "-1.5"),
            (value: "b'1'", extra: "", type: "BIT(1)", expected: "b'1'"),
            (value: "0x61", extra: "", type: "VARBINARY(8)", expected: "0x61"),
            (value: "1", extra: "", type: "TINYINT(1)", expected: "1"),
            (value: "CURRENT_TIMESTAMP", extra: "", type: "TIMESTAMP", expected: "CURRENT_TIMESTAMP"),
            (value: "CURRENT_TIMESTAMP", extra: "DEFAULT_GENERATED", type: "TIMESTAMP",
             expected: "CURRENT_TIMESTAMP"),
            (value: "CURRENT_TIMESTAMP", extra: "DEFAULT_GENERATED", type: "DATETIME(6)",
             expected: "CURRENT_TIMESTAMP"),
            (value: "CURRENT_TIMESTAMP", extra: "", type: "DATETIME(6)", expected: "CURRENT_TIMESTAMP"),
            (value: "CURRENT_TIMESTAMP", extra: "", type: "VARCHAR(32)", expected: "'CURRENT_TIMESTAMP'"),
            (value: "active", extra: "", type: "enum('active','inactive')", expected: "'active'"),
            (value: "uuid()", extra: "DEFAULT_GENERATED", type: "VARCHAR(36)", expected: "(uuid())"),
            (value: "(curdate() + interval 1 year)", extra: "DEFAULT_GENERATED", type: "DATE",
             expected: "(curdate() + interval 1 year)")
        ]
    )
    func catalogDefaultRoundTrip(value: String, extra: String, type: String, expected: String) {
        for isNullable in [true, false] {
            #expect(mysqlColumnDefault(.bare(value), extra: extra, dataType: type, isNullable: isNullable) == expected)
        }
    }

    /// #3058. MySQL writes `DEFAULT NULL` itself for a nullable column declared without a default, and
    /// both servers report it as SQL NULL, the same answer they give for a NOT NULL column with no
    /// default at all. Only the column's nullability tells the two apart.
    @Test(
        "SQL NULL is DEFAULT NULL on a nullable column and no default on a NOT NULL one",
        arguments: [
            MySQLCatalogDefault.bare(nil),
            MySQLCatalogDefault.quoted(nil)
        ]
    )
    func catalogNullFollowsNullability(catalog: MySQLCatalogDefault) {
        for type in ["VARCHAR(255)", "INT", "TEXT", "JSON", "TIMESTAMP", "enum('a','b')"] {
            #expect(mysqlColumnDefault(catalog, extra: "", dataType: type, isNullable: true) == "NULL", "\(type)")
            #expect(mysqlColumnDefault(catalog, extra: "", dataType: type, isNullable: false) == nil, "\(type)")
        }
    }

    /// MariaDB reports a generated column's default as the text `NULL`, and both servers refuse a
    /// `DEFAULT` on a generated or AUTO_INCREMENT column, so neither may read as having one.
    @Test(
        "A generated or AUTO_INCREMENT column has no default whatever the catalog says",
        arguments: [
            (catalog: MySQLCatalogDefault.quoted("NULL"), extra: "VIRTUAL GENERATED"),
            (catalog: MySQLCatalogDefault.quoted("NULL"), extra: "STORED GENERATED"),
            (catalog: MySQLCatalogDefault.bare(nil), extra: "VIRTUAL GENERATED"),
            (catalog: MySQLCatalogDefault.bare(nil), extra: "PERSISTENT"),
            (catalog: MySQLCatalogDefault.bare(nil), extra: "auto_increment"),
            (catalog: MySQLCatalogDefault.quoted(nil), extra: "auto_increment")
        ]
    )
    func generatedAndAutoIncrementHaveNoDefault(catalog: MySQLCatalogDefault, extra: String) {
        #expect(mysqlColumnDefault(catalog, extra: extra, dataType: "INT", isNullable: true) == nil)
        #expect(mysqlColumnDefault(catalog, extra: extra, dataType: "INT", isNullable: false) == nil)
    }

    /// `INFORMATION_SCHEMA.COLUMNS.COLUMN_DEFAULT` on MariaDB 12.3.3, byte for byte: literals quoted,
    /// expressions bare, and `DEFAULT NULL` as the unquoted text `NULL`.
    @Test(
        "A MariaDB catalog default is already the SQL",
        arguments: [
            (value: "NULL", type: "VARCHAR(255)"),
            (value: "'NULL'", type: "VARCHAR(10)"),
            (value: "'abc'", type: "VARCHAR(10)"),
            (value: "''", type: "VARCHAR(10)"),
            (value: "'it''s'", type: "VARCHAR(40)"),
            (value: #"'x\\y'"#, type: "VARCHAR(40)"),
            (value: #"'l1\nl2'"#, type: "VARCHAR(40)"),
            (value: "'q'", type: "TEXT"),
            (value: "'a'", type: "enum('a','b')"),
            (value: "uuid()", type: "VARCHAR(36)"),
            (value: "concat('a','b')", type: "VARCHAR(40)"),
            (value: "current_timestamp()", type: "DATETIME"),
            (value: "5", type: "INT(11)"),
            (value: "1.50", type: "DECIMAL(5,2)"),
            (value: "b'1'", type: "BIT(1)"),
            (value: "x'61'", type: "VARBINARY(4)")
        ]
    )
    func mariaDBCatalogDefaultPassesThrough(value: String, type: String) {
        #expect(mysqlColumnDefault(.quoted(value), extra: "", dataType: type, isNullable: true) == value)
    }

    /// MariaDB's `SHOW FULL COLUMNS` never quotes, whatever the version: measured on 12.3.3 it answers
    /// `abc` for `'abc'`, an empty string for `''` and the text `NULL` for the string `'NULL'`. That
    /// read is what a MariaDB connection falls back to when its catalog is blind or refuses, so it
    /// has to be decoded as bare, where the text `NULL` and SQL NULL stay apart.
    @Test(
        "A MariaDB SHOW FULL COLUMNS default is decoded as bare",
        arguments: [
            (value: "abc", expected: "'abc'"),
            (value: "", expected: "''"),
            (value: "NULL", expected: "'NULL'"),
            (value: "it's", expected: "'it''s'")
        ]
    )
    func mariaDBShowColumnsDefaultIsBare(value: String, expected: String) {
        #expect(mysqlColumnDefault(.bare(value), extra: "", dataType: "VARCHAR(10)", isNullable: true) == expected)
    }

    /// What a MariaDB whose catalog does not answer in the quoted form falls back to: `SHOW CREATE
    /// TABLE`, verbatim from MariaDB 13.0.2. Its `SHOW FULL COLUMNS` reports `k`'s expression and a
    /// string of the same text alike, so reading that instead turns `concat('x',uuid())` into the
    /// constant string the next time the column is written.
    @Test("A MariaDB SHOW CREATE TABLE default reads like its catalog's")
    func mariaDBCreateTableDefaultsReadLikeTheCatalog() throws {
        let createTable = """
            CREATE TABLE `t` (
              `a` int(11) DEFAULT (1 + 2),
              `b` int(11) DEFAULT -5,
              `c` varchar(20) DEFAULT 'a b',
              `d` varchar(40) DEFAULT concat('a','b'),
              `e` bigint(20) DEFAULT nextval(`p2`.`s1`),
              `f` datetime(6) DEFAULT current_timestamp(6) ON UPDATE current_timestamp(6),
              `g` varchar(10) DEFAULT 'x' COMMENT 'c,d',
              `h` varchar(10) NOT NULL,
              `i` text DEFAULT 'q',
              `n` varchar(10) DEFAULT NULL,
              `k` varchar(40) DEFAULT concat('x',uuid()),
              `we ird` varchar(5) DEFAULT 'y',
              `l` varchar(10) DEFAULT 'it''s, ok'
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci
            """
        let clauses = try #require(MySQLCreateTableScanner.columnDefaultClauses(fromCreateTable: createTable))
        let expected: [(name: String, type: String, isNullable: Bool, sql: String?)] = [
            ("a", "INT(11)", true, "(1 + 2)"),
            ("b", "INT(11)", true, "-5"),
            ("c", "VARCHAR(20)", true, "'a b'"),
            ("d", "VARCHAR(40)", true, "concat('a','b')"),
            ("e", "BIGINT(20)", true, "nextval(`p2`.`s1`)"),
            ("f", "DATETIME(6)", true, "current_timestamp(6)"),
            ("g", "VARCHAR(10)", true, "'x'"),
            ("h", "VARCHAR(10)", false, nil),
            ("i", "TEXT", true, "'q'"),
            ("n", "VARCHAR(10)", true, "NULL"),
            ("k", "VARCHAR(40)", true, "concat('x',uuid())"),
            ("we ird", "VARCHAR(5)", true, "'y'"),
            ("l", "VARCHAR(10)", true, "'it''s, ok'")
        ]
        for column in expected {
            let resolved = mysqlColumnDefault(
                .quoted(clauses[column.name]), extra: "", dataType: column.type, isNullable: column.isNullable
            )
            #expect(resolved == column.sql, "\(column.name)")
        }
    }

    /// MySQL keeps an expression default escaped in its catalog, and non-ASCII text in it encoded twice
    /// (`日` comes back as `æ\u{97}¥`), so an expression default is taken from `SHOW CREATE TABLE`.
    /// Verbatim from MySQL 8.4.11.
    @Test("A MySQL expression default reads from SHOW CREATE TABLE exactly, non-ASCII text included")
    func mysqlExpressionDefaultsReadFromCreateTable() throws {
        let createTable = """
            CREATE TABLE `mx` (
              `a` varchar(20) DEFAULT (concat(_utf8mb4'日',_utf8mb4'x')),
              `b` varchar(20) CHARACTER SET latin1 COLLATE latin1_swedish_ci DEFAULT (concat(_utf8mb4'é',_utf8mb4'x')),
              `c` timestamp NULL DEFAULT CURRENT_TIMESTAMP,
              `f` text DEFAULT (NULL),
              `g` int DEFAULT ((1 + 2)),
              `i` int DEFAULT '5',
              `日本` varchar(5) DEFAULT (upper(_utf8mb4'ü'))
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
            """
        let clauses = try #require(MySQLCreateTableScanner.columnDefaultClauses(fromCreateTable: createTable))
        let defaults = MySQLCreateTableDefaults(clauses: clauses, scope: .expressionDefaults)
        let generated = "DEFAULT_GENERATED"

        #expect(defaults.catalogDefault(forColumn: "a", extra: generated) == .quoted("(concat(_utf8mb4'日',_utf8mb4'x'))"))
        #expect(defaults.catalogDefault(forColumn: "b", extra: generated) == .quoted("(concat(_utf8mb4'é',_utf8mb4'x'))"))
        #expect(defaults.catalogDefault(forColumn: "f", extra: generated) == .quoted("(NULL)"))
        #expect(defaults.catalogDefault(forColumn: "g", extra: generated) == .quoted("((1 + 2))"))
        #expect(defaults.catalogDefault(forColumn: "日本", extra: generated) == .quoted("(upper(_utf8mb4'ü'))"))
        #expect(defaults.catalogDefault(forColumn: "i", extra: "") == nil)
        #expect(defaults.catalogDefault(forColumn: "missing", extra: generated) == nil)
    }

    /// A quoted identifier may hold a line break and a string default may hold a comma. Read line by
    /// line, the first handed the rest of its name's line to another column as that column's default.
    @Test("A line break in a quoted name or a comma in a default moves no default to another column")
    func lineBreakInQuotedNameKeepsDefaultsInPlace() throws {
        let createTable = """
            CREATE TABLE `t` (
              `a` varchar(10) DEFAULT 'x',
              `we
            ird` varchar(5) DEFAULT 'y, z',
              `b` int DEFAULT NULL,
              PRIMARY KEY (`a`),
              KEY `k` (`b`)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
            """
        let clauses = try #require(MySQLCreateTableScanner.columnDefaultClauses(fromCreateTable: createTable))
        #expect(clauses == ["a": "'x'", "we\nird": "'y, z'", "b": "NULL"])
    }

    @Test("SHOW CREATE TABLE answers every column for a MariaDB, and a missing clause is no default")
    func everyColumnScopeAnswersForAll() {
        let defaults = MySQLCreateTableDefaults(clauses: ["a": "'x'"], scope: .everyColumn)
        #expect(defaults.catalogDefault(forColumn: "a", extra: "") == .quoted("'x'"))
        #expect(defaults.catalogDefault(forColumn: "b", extra: "") == .quoted(nil))
    }

    /// The catalog's escaping is undone exactly, its double encoding of non-ASCII text is not.
    @Test(
        "Only a MySQL expression default holding non-ASCII text needs SHOW CREATE TABLE",
        arguments: [
            (value: "concat(_utf8mb4\\'\u{E6}\u{97}\u{A5}\\',_utf8mb4\\'x\\')", extra: "DEFAULT_GENERATED",
             type: "VARCHAR(20)", needs: true),
            (value: "upper(_utf8mb4\\'\u{C3}\u{BC}\\')", extra: "DEFAULT_GENERATED", type: "VARCHAR(5)", needs: true),
            (value: "uuid()", extra: "DEFAULT_GENERATED", type: "VARCHAR(36)", needs: false),
            (value: "concat(_utf8mb4\\'it\\\\\\'s\\')", extra: "DEFAULT_GENERATED", type: "VARCHAR(40)", needs: false),
            (value: "NULL", extra: "DEFAULT_GENERATED", type: "TEXT", needs: false),
            (value: "CURRENT_TIMESTAMP", extra: "DEFAULT_GENERATED", type: "TIMESTAMP", needs: false),
            (value: "caf\u{E9}", extra: "", type: "VARCHAR(10)", needs: false)
        ]
    )
    func expressionDefaultsNeedCreateTable(value: String, extra: String, type: String, needs: Bool) {
        #expect(mysqlExpressionDefaultNeedsCreateTable(value, extra: extra, dataType: type) == needs)
    }

    /// Before 10.2.7 a MariaDB catalog reports `uuid()` and the string `'uuid()'` alike.
    @Test(
        "A bare MariaDB default may be an expression only when it holds a parenthesis",
        arguments: [
            (value: "uuid()", type: "VARCHAR(36)", may: true),
            (value: "concat('a','b')", type: "VARCHAR(10)", may: true),
            (value: "(1 + 2)", type: "INT(11)", may: true),
            (value: "current_timestamp()", type: "DATETIME", may: false),
            (value: "abc", type: "VARCHAR(10)", may: false),
            (value: "5", type: "INT(11)", may: false)
        ]
    )
    func mariaDBBareDefaultsThatMayBeExpressions(value: String, type: String, may: Bool) {
        #expect(mariaDBBareDefaultMayBeExpression(value, dataType: type) == may)
    }

    @Test("A catalog expression holding non-ASCII text is left escaped rather than rewritten")
    func nonASCIIExpressionIsNotUnescaped() {
        let doubleEncoded = "concat(_utf8mb4\\'\u{E6}\u{97}\u{A5}\\',_utf8mb4\\'x\\')"
        #expect(mysqlUnescapedCatalogExpression(doubleEncoded) == doubleEncoded)
    }

    /// MySQL 8.4.11 backslash-escapes every quote and backslash in an expression default, relative to
    /// what `SHOW CREATE TABLE` prints. Measured from `HEX(COLUMN_DEFAULT)`.
    @Test(
        "A MySQL expression default is unescaped back to the SQL it was written as",
        arguments: [
            (value: #"concat(_utf8mb4\'a\',_utf8mb4\'b\')"#, type: "VARCHAR(40)",
             expected: #"(concat(_utf8mb4'a',_utf8mb4'b'))"#),
            (value: #"_utf8mb4\'it\\\'s\'"#, type: "VARCHAR(40)", expected: #"(_utf8mb4'it\'s')"#),
            (value: #"concat(_utf8mb4\'x\\\\y\',_utf8mb4\'z\')"#, type: "VARCHAR(40)",
             expected: #"(concat(_utf8mb4'x\\y',_utf8mb4'z'))"#),
            (value: #"concat(_utf8mb4\'l1\\nl2\',_utf8mb4\'\')"#, type: "VARCHAR(40)",
             expected: #"(concat(_utf8mb4'l1\nl2',_utf8mb4''))"#),
            (value: #"json_object(_utf8mb4\'k\',_utf8mb4\'v\')"#, type: "JSON",
             expected: #"(json_object(_utf8mb4'k',_utf8mb4'v'))"#),
            (value: "NULL", type: "TEXT", expected: "(NULL)")
        ]
    )
    func mysqlExpressionDefaultIsUnescaped(value: String, type: String, expected: String) {
        let resolved = mysqlColumnDefault(.bare(value), extra: "DEFAULT_GENERATED", dataType: type, isNullable: true)
        #expect(resolved == expected)
    }

    /// A server that stops escaping would hand back the SQL itself, which always holds a bare quote
    /// wherever it holds a string, so the scan leaves it as it came rather than eating its backslashes.
    @Test(
        "Text that was never escaped is returned unchanged",
        arguments: [
            #"concat(_utf8mb4'a',_utf8mb4'b')"#,
            #"(_utf8mb4'it\'s')"#,
            #"concat('x\\y','z')"#,
            "uuid()",
            "(curdate() + interval 1 year)",
            #"trailing\"#
        ]
    )
    func unescapedExpressionPassesThrough(value: String) {
        #expect(mysqlUnescapedCatalogExpression(value) == value)
    }

    /// MariaDB began quoting `COLUMN_DEFAULT` in 10.2.7. Before that it reads like MySQL without the
    /// `DEFAULT_GENERATED` marker, so a bare literal has to be quoted rather than passed through.
    @Test(
        "Whether the catalog quotes its literals follows the server version",
        arguments: [
            (banner: "10.6.16-MariaDB", isMariaDB: true, expected: true),
            (banner: "10.2.7-MariaDB", isMariaDB: true, expected: true),
            (banner: "10.2.6-MariaDB", isMariaDB: true, expected: false),
            (banner: "10.1.48-MariaDB", isMariaDB: true, expected: false),
            (banner: "10.0.38-MariaDB", isMariaDB: true, expected: false),
            (banner: "8.4.11", isMariaDB: false, expected: false),
            (banner: "5.7.44", isMariaDB: false, expected: false)
        ]
    )
    func catalogQuotingFollowsTheVersion(banner: String, isMariaDB: Bool, expected: Bool) {
        #expect(
            MySQLServerVersion.quotesColumnDefault(banner: banner, flavor: isMariaDB ? .mariadb : .mysql) == expected
        )
    }

    /// The whole of #3058 in one line: the default a nullable column reads back is written as
    /// `DEFAULT NULL`, which the next read turns into the same `NULL` again.
    @Test("A nullable column's NULL default survives a read and a rewrite")
    func nullDefaultRoundTrips() {
        let read = mysqlColumnDefault(.bare(nil), extra: "", dataType: "VARCHAR(255)", isNullable: true)
        let column = PluginColumnDefinition(name: "Name", dataType: "VARCHAR(255)", isNullable: true, defaultValue: read)
        #expect(mysqlColumnDefinitionSQL(column) == "`Name` VARCHAR(255) NULL DEFAULT NULL")
    }

    /// `DEFAULT (NULL)` is an expression default on MySQL 8 and a syntax error on MySQL 5.7, while a
    /// bare `DEFAULT NULL` is taken by every type, including the four whose other defaults need
    /// parentheses.
    @Test(
        "NULL is written bare on every type and for both servers",
        arguments: ["TEXT", "LONGBLOB", "JSON", "GEOMETRY", "VARCHAR(16)", "INT", "TIMESTAMP"]
    )
    func nullDefaultIsNeverParenthesised(dataType: String) {
        for isMariaDB in [false, true] {
            #expect(mysqlDefaultValueLiteral("NULL", dataType: dataType, isMariaDB: isMariaDB) == "NULL")
            #expect(mysqlDefaultValueLiteral("null", dataType: dataType, isMariaDB: isMariaDB) == "NULL")
        }
        let column = PluginColumnDefinition(name: "c", dataType: dataType, isNullable: true, defaultValue: "NULL")
        #expect(mysqlColumnDefinitionSQL(column).hasSuffix(" NULL DEFAULT NULL"))
    }

    @Test("An expression default of NULL keeps the parentheses it was read with")
    func parenthesisedNullExpressionIsKept() {
        #expect(mysqlDefaultValueLiteral("(NULL)", dataType: "TEXT", isMariaDB: false) == "(NULL)")
    }

    @Test("A numeric default is unquoted")
    func numericDefaultStaysUnquoted() {
        let column = PluginColumnDefinition(
            name: "qty", dataType: "INT", isNullable: false, defaultValue: "0"
        )
        #expect(mysqlColumnDefinitionSQL(column).contains("DEFAULT 0"))
    }

    // MARK: - Precision Extraction

    @Test(
        "Fractional-second precision comes from the declared type only",
        arguments: [
            (dataType: "TIMESTAMP", expected: ""),
            (dataType: "TIMESTAMP(6)", expected: "(6)"),
            (dataType: "timestamp(3)", expected: "(3)"),
            (dataType: "DATETIME", expected: ""),
            (dataType: "DATETIME(0)", expected: "(0)"),
            (dataType: "VARCHAR(255)", expected: ""),
            (dataType: "ENUM('a(1)','b')", expected: "")
        ]
    )
    func precisionExtraction(dataType: String, expected: String) {
        #expect(mysqlFractionalSecondsSuffix(forDataType: dataType) == expected)
    }

    // MARK: - Other Attributes

    @Test("Charset, collation, unsigned, and auto increment all render")
    func attributesRender() {
        let column = PluginColumnDefinition(
            name: "id",
            dataType: "BIGINT",
            isNullable: false,
            autoIncrement: true,
            unsigned: true,
            charset: "utf8mb4",
            collation: "utf8mb4_general_ci"
        )

        let sql = mysqlColumnDefinitionSQL(column)
        #expect(sql.contains("`id` BIGINT"))
        #expect(sql.contains("UNSIGNED"))
        #expect(sql.contains("CHARACTER SET utf8mb4"))
        #expect(sql.contains("COLLATE utf8mb4_general_ci"))
        #expect(sql.contains("NOT NULL"))
        #expect(sql.contains("AUTO_INCREMENT"))
    }

    @Test("A backtick in a column name is escaped")
    func backtickEscaping() {
        let column = PluginColumnDefinition(name: "col`name", dataType: "INT")
        #expect(mysqlColumnDefinitionSQL(column).contains("`col``name`"))
    }
}
