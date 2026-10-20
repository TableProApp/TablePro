import Foundation
@testable import TableProModels
@testable import TableProPluginKit
@testable import TableProQuery
import Testing

struct FilterSQLGeneratorTests {
    private var dialect: SQLDialectDescriptor {
        SQLDialectDescriptor(
            identifierQuote: "\"",
            keywords: [],
            functions: [],
            dataTypes: [],
            likeEscapeStyle: .explicit
        )
    }

    @Test("Equal filter generates correct SQL")
    func equalFilter() {
        let generator = FilterSQLGenerator(dialect: dialect)
        let filter = TableFilter(columnName: "name", filterOperator: .equal, value: "Alice")
        let result = generator.generateWhereClause(from: [filter], logicMode: .and)
        #expect(result == "WHERE \"name\" = 'Alice'")
    }

    @Test("Numeric values are not quoted")
    func numericValues() {
        let generator = FilterSQLGenerator(dialect: dialect)
        let filter = TableFilter(columnName: "age", filterOperator: .greaterThan, value: "25")
        let result = generator.generateWhereClause(from: [filter], logicMode: .and)
        #expect(result == "WHERE \"age\" > 25")
    }

    @Test("IS NULL filter")
    func isNullFilter() {
        let generator = FilterSQLGenerator(dialect: dialect)
        let filter = TableFilter(columnName: "email", filterOperator: .isNull)
        let result = generator.generateWhereClause(from: [filter], logicMode: .and)
        #expect(result == "WHERE \"email\" IS NULL")
    }

    @Test("Multiple filters with AND")
    func multipleFiltersAnd() {
        let generator = FilterSQLGenerator(dialect: dialect)
        let filters = [
            TableFilter(columnName: "age", filterOperator: .greaterThan, value: "18"),
            TableFilter(columnName: "active", filterOperator: .equal, value: "1")
        ]
        let result = generator.generateWhereClause(from: filters, logicMode: .and)
        #expect(result.contains("AND"))
        #expect(result.hasPrefix("WHERE"))
    }

    @Test("Multiple filters with OR")
    func multipleFiltersOr() {
        let generator = FilterSQLGenerator(dialect: dialect)
        let filters = [
            TableFilter(columnName: "status", filterOperator: .equal, value: "active"),
            TableFilter(columnName: "status", filterOperator: .equal, value: "pending")
        ]
        let result = generator.generateWhereClause(from: filters, logicMode: .or)
        #expect(result.contains("OR"))
    }

    @Test("Disabled filters are excluded")
    func disabledFiltersExcluded() {
        let generator = FilterSQLGenerator(dialect: dialect)
        let filters = [
            TableFilter(columnName: "name", filterOperator: .equal, value: "test", isEnabled: false),
            TableFilter(columnName: "age", filterOperator: .greaterThan, value: "10", isEnabled: true)
        ]
        let result = generator.generateWhereClause(from: filters, logicMode: .and)
        #expect(!result.contains("name"))
        #expect(result.contains("age"))
    }

    @Test("Empty active filters returns empty string")
    func emptyFilters() {
        let generator = FilterSQLGenerator(dialect: dialect)
        let result = generator.generateWhereClause(from: [], logicMode: .and)
        #expect(result == "")
    }

    @Test("BETWEEN filter")
    func betweenFilter() {
        let generator = FilterSQLGenerator(dialect: dialect)
        let filter = TableFilter(
            columnName: "price",
            filterOperator: .between,
            value: "10",
            secondValue: "100"
        )
        let result = generator.generateWhereClause(from: [filter], logicMode: .and)
        #expect(result == "WHERE \"price\" BETWEEN 10 AND 100")
    }

    @Test("CONTAINS filter uses LIKE with wildcards")
    func containsFilter() {
        let generator = FilterSQLGenerator(dialect: dialect)
        let filter = TableFilter(columnName: "name", filterOperator: .contains, value: "test")
        let result = generator.generateWhereClause(from: [filter], logicMode: .and)
        #expect(result.contains("LIKE '%test%'"))
    }

    @Test("Explicit dialect LIKE uses a non-backslash ESCAPE clause")
    func explicitLikeEscapeIsNotBackslash() {
        let generator = FilterSQLGenerator(dialect: dialect)
        let filter = TableFilter(columnName: "name", filterOperator: .contains, value: "50%")
        let result = generator.generateWhereClause(from: [filter], logicMode: .and)
        #expect(result.contains("ESCAPE '!'"))
        #expect(!result.contains("ESCAPE '\\'"))
    }

    @Test("Explicit dialect LIKE escapes a literal exclamation mark in the value")
    func explicitLikeEscapesExclamation() {
        let generator = FilterSQLGenerator(dialect: dialect)
        let filter = TableFilter(columnName: "name", filterOperator: .contains, value: "a!b")
        let result = generator.generateWhereClause(from: [filter], logicMode: .and)
        #expect(result.contains("a!!b"))
    }

    @Test("Implicit dialect LIKE keeps backslash escaping and no ESCAPE clause")
    func implicitLikeUsesBackslash() {
        let implicit = SQLDialectDescriptor(
            identifierQuote: "`",
            keywords: [],
            functions: [],
            dataTypes: [],
            likeEscapeStyle: .implicit
        )
        let generator = FilterSQLGenerator(dialect: implicit)
        let filter = TableFilter(columnName: "name", filterOperator: .contains, value: "a_b")
        let result = generator.generateWhereClause(from: [filter], logicMode: .and)
        #expect(result.contains("a\\_b"))
        #expect(!result.contains("ESCAPE"))
    }

    @Test("Raw SQL filter passes through")
    func rawSQLFilter() {
        let generator = FilterSQLGenerator(dialect: dialect)
        let filter = TableFilter(
            columnName: TableFilter.rawSQLColumn,
            rawSQL: "age > 10 AND active = 1"
        )
        let result = generator.generateWhereClause(from: [filter], logicMode: .and)
        #expect(result == "WHERE age > 10 AND active = 1")
    }

    @Test("IN filter")
    func inFilter() {
        let generator = FilterSQLGenerator(dialect: dialect)
        let filter = TableFilter(columnName: "status", filterOperator: .in, value: "active,pending,new")
        let result = generator.generateWhereClause(from: [filter], logicMode: .and)
        #expect(result.contains("IN"))
        #expect(result.contains("'active'"))
        #expect(result.contains("'pending'"))
    }

    private func makeDialect(quote: String, backslashEscaping: Bool = false) -> SQLDialectDescriptor {
        SQLDialectDescriptor(
            identifierQuote: quote,
            keywords: [],
            functions: [],
            dataTypes: [],
            likeEscapeStyle: backslashEscaping ? .implicit : .explicit,
            requiresBackslashEscaping: backslashEscaping
        )
    }

    private func clause(
        _ column: String,
        _ value: String,
        op filterOperator: FilterOperator = .equal,
        columns: [ColumnInfo] = [],
        dialect: SQLDialectDescriptor? = nil
    ) -> String {
        FilterSQLGenerator(dialect: dialect ?? self.dialect).generateWhereClause(
            from: [TableFilter(columnName: column, filterOperator: filterOperator, value: value)],
            logicMode: .and,
            columns: columns
        )
    }

    @Test("A bracket-quoted identifier closes with a bracket")
    func bracketIdentifierCloses() {
        #expect(clause("id", "5", dialect: makeDialect(quote: "[")) == "WHERE [id] = 5")
    }

    @Test("A closing bracket inside a bracket-quoted identifier is doubled")
    func bracketInsideIdentifierIsDoubled() {
        #expect(clause("a]b", "5", dialect: makeDialect(quote: "[")) == "WHERE [a]]b] = 5")
    }

    @Test("A backslash is doubled where the engine reads it as an escape")
    func backslashIsDoubled() {
        let mysql = makeDialect(quote: "`", backslashEscaping: true)
        #expect(clause("path", "C:\\temp\\", dialect: mysql) == "WHERE `path` = 'C:\\\\temp\\\\'")
        #expect(clause("code", "a\\' OR 1=1 -- ", dialect: mysql) == "WHERE `code` = 'a\\\\'' OR 1=1 -- '")
    }

    @Test("A backslash stays single where the engine reads it as a character")
    func backslashStaysSingle() {
        #expect(clause("path", "C:\\temp") == "WHERE \"path\" = 'C:\\temp'")
    }

    @Test("A number-like value against a text column is quoted")
    func numberLikeTextIsQuoted() {
        let columns = [ColumnInfo(name: "code", typeName: "varchar(10)")]
        #expect(clause("code", "02134", columns: columns) == "WHERE \"code\" = '02134'")
    }

    @Test("A filter column spelled in another case still finds its type")
    func caseFoldedColumnFindsType() {
        let columns = [ColumnInfo(name: "code", typeName: "TEXT")]
        #expect(clause("CODE", "02134", columns: columns) == "WHERE \"CODE\" = '02134'")
    }

    @Test("Two case-insensitive matches resolve no column, so the untyped rule applies")
    func ambiguousCaseFoldedColumn() {
        let columns = [ColumnInfo(name: "Code", typeName: "TEXT"), ColumnInfo(name: "CODE", typeName: "TEXT")]
        #expect(FilterColumnKind.column(named: "code", in: columns)?.name == nil)
        #expect(clause("code", "02134", columns: columns) == "WHERE \"code\" = 02134")
    }

    @Test("An exact name wins over a case-insensitive one")
    func exactNameWins() {
        let columns = [ColumnInfo(name: "code", typeName: "TEXT"), ColumnInfo(name: "CODE", typeName: "integer")]
        #expect(clause("CODE", "5", columns: columns) == "WHERE \"CODE\" = 5")
    }

    @Test("Types outside the numeric allowlist are quoted", arguments: ["interval", "point", "uuid", "money"])
    func unlistedTypeIsQuoted(typeName: String) {
        let columns = [ColumnInfo(name: "v", typeName: typeName)]
        #expect(clause("v", "5", columns: columns) == "WHERE \"v\" = '5'")
    }

    @Test("Integer and decimal types stay bare", arguments: ["bit", "tinyint(1)", "NUMBER(10)", "int(11) unsigned", "double precision"])
    func numericTypeStaysBare(typeName: String) {
        let columns = [ColumnInfo(name: "v", typeName: typeName)]
        #expect(clause("v", "1", columns: columns) == "WHERE \"v\" = 1")
    }

    @Test("A greater-than against an INT column stays bare")
    func intGreaterThanStaysBare() {
        let columns = [ColumnInfo(name: "age", typeName: "INT")]
        #expect(clause("age", "25", op: .greaterThan, columns: columns) == "WHERE \"age\" > 25")
    }

    @Test("A fraction against an integer column stays bare, since PostgreSQL rejects bigint > '5.5'")
    func fractionAgainstIntegerStaysBare() {
        let columns = [ColumnInfo(name: "id", typeName: "bigint")]
        #expect(clause("id", "5.5", op: .greaterThan, columns: columns) == "WHERE \"id\" > 5.5")
    }

    @Test("A typeless column keeps the untyped rule")
    func typelessColumnStaysUntyped() {
        let columns = [ColumnInfo(name: "v", typeName: "")]
        #expect(clause("v", "5", columns: columns) == "WHERE \"v\" = 5")
    }

    @Test("A column without SQLite affinity keeps the untyped rule", arguments: ["BLOB", "longblob", "ANY"])
    func noAffinityColumnStaysUntyped(typeName: String) {
        let columns = [ColumnInfo(name: "v", typeName: typeName)]
        #expect(clause("v", "5", columns: columns) == "WHERE \"v\" = 5")
    }

    @Test("Values Swift parses as a number but SQL does not are quoted", arguments: ["nan", "inf", "Infinity", "0x1F"])
    func swiftOnlyNumbersAreQuoted(value: String) {
        #expect(clause("v", value) == "WHERE \"v\" = '\(value)'")
        let columns = [ColumnInfo(name: "v", typeName: "double")]
        #expect(clause("v", value, columns: columns) == "WHERE \"v\" = '\(value)'")
    }

    @Test("Digits of another script are quoted")
    func nonASCIIDigitsAreQuoted() {
        #expect(clause("v", "\u{0663}") == "WHERE \"v\" = '\u{0663}'")
    }

    @Test("Every IN item and both BETWEEN bounds follow the column's type")
    func listAndRangeFollowType() {
        let columns = [ColumnInfo(name: "code", typeName: "varchar")]
        #expect(clause("code", "01, 02", op: .in, columns: columns) == "WHERE \"code\" IN ('01', '02')")
        let range = FilterSQLGenerator(dialect: dialect).generateWhereClause(
            from: [TableFilter(columnName: "code", filterOperator: .between, value: "01", secondValue: "09")],
            logicMode: .and,
            columns: columns
        )
        #expect(range == "WHERE \"code\" BETWEEN '01' AND '09'")
    }

    @Test("Type names map to a column kind", arguments: [
        ("INTEGER", PluginColumnKind.integer),
        ("int4", .integer),
        ("bigint(20) unsigned zerofill", .integer),
        ("UNSIGNED INTEGER", .integer),
        ("tinyint(1)", .integer),
        ("bit", .integer),
        ("boolean", .integer),
        ("bool", .integer),
        ("NUMBER(10)", .decimal),
        ("numeric(10,2)", .decimal),
        ("double precision", .decimal),
        ("REAL", .decimal),
        ("float8", .decimal),
        ("DECIMAL(18,3)", .decimal),
        ("varchar(255)", .text),
        ("character varying", .text),
        ("TEXT", .text),
        ("interval", .text),
        ("point", .text),
        ("bit varying", .text),
        ("BIT VARYING(8)", .text),
        ("", .text)
    ])
    func typeNameKind(typeName: String, kind: PluginColumnKind) {
        #expect(FilterColumnKind.kind(forTypeName: typeName) == kind)
    }

    private func engineClause(
        _ type: DatabaseType,
        _ column: ColumnInfo,
        _ value: String,
        op filterOperator: FilterOperator = .equal,
        isCaseSensitive: Bool? = nil,
        dialect: SQLDialectDescriptor? = nil
    ) -> String {
        FilterSQLGenerator(dialect: dialect ?? self.dialect, databaseType: type).generateWhereClause(
            from: [TableFilter(
                columnName: column.name, filterOperator: filterOperator, value: value, isCaseSensitive: isCaseSensitive
            )],
            logicMode: .and,
            columns: [column]
        )
    }

    // Measured on PostgreSQL 17: `bit = 101` and `boolean = 1` have no operator, and `real = 0.1` finds no row.
    @Test("PostgreSQL compares every column but an integer one to a quoted literal",
          arguments: ["bit(3)", "bit", "boolean", "real", "double precision", "numeric(10,2)"])
    func postgresQuotesNonIntegerColumns(typeName: String) {
        let column = ColumnInfo(name: "v", typeName: typeName)
        #expect(engineClause(.postgresql, column, "1") == "WHERE \"v\" = '1'")
        #expect(engineClause(.redshift, column, "1") == "WHERE \"v\" = '1'")
    }

    @Test("A PostgreSQL integer column keeps a bare number, a fraction included")
    func postgresIntegerStaysBare() {
        let column = ColumnInfo(name: "id", typeName: "integer")
        #expect(engineClause(.postgresql, column, "5") == "WHERE \"id\" = 5")
        #expect(engineClause(.postgresql, column, "5.5", op: .greaterThan) == "WHERE \"id\" > 5.5")
    }

    // DuckDB runs `bit = 101` and returns no row; MySQL 8.4 and MariaDB 13 return no row for `bit = '5'`.
    @Test("A BIT column is a bit string on DuckDB and a number on MySQL")
    func bitFollowsTheEngine() {
        let bit = ColumnInfo(name: "b", typeName: "BIT")
        #expect(engineClause(.duckdb, bit, "101") == "WHERE \"b\" = '101'")
        #expect(engineClause(.mysql, ColumnInfo(name: "b", typeName: "bit(8)"), "5") == "WHERE \"b\" = 5")
        #expect(engineClause(.duckdb, ColumnInfo(name: "f", typeName: "FLOAT"), "0.1") == "WHERE \"f\" = 0.1")
    }

    // SQLite keeps integer 5 and text '5' apart in a column with no affinity, and the grid shows both as 5.
    @Test("A SQLite column with no affinity matches a number either way it was stored", arguments: ["", "BLOB", "ANY"])
    func sqliteUntypedMatchesEitherStorageClass(typeName: String) {
        let column = ColumnInfo(name: "v", typeName: typeName)
        #expect(engineClause(.sqlite, column, "5") == "WHERE \"v\" IN (5, '5')")
        #expect(engineClause(.sqlite, column, "5", op: .notEqual) == "WHERE \"v\" NOT IN (5, '5')")
        #expect(engineClause(.sqlite, column, "5, abc, 05", op: .in) == "WHERE \"v\" IN (5, '5', 'abc', '05')")
        #expect(engineClause(.sqlite, column, "-2.5", op: .notIn) == "WHERE \"v\" NOT IN (-2.5, '-2.5')")
        #expect(engineClause(.sqlite, column, "02134") == "WHERE \"v\" = '02134'")
        #expect(engineClause(.sqlite, column, "1.0e+20") == "WHERE \"v\" IN (1.0e+20, '1.0e+20')")
        #expect(engineClause(.sqlite, column, "5", op: .greaterThan) == "WHERE \"v\" > 5")
    }

    @Test("A typed SQLite column keeps its literal")
    func sqliteTypedColumnUnchanged() {
        #expect(engineClause(.sqlite, ColumnInfo(name: "id", typeName: "INTEGER"), "5") == "WHERE \"id\" = 5")
        #expect(engineClause(.sqlite, ColumnInfo(name: "code", typeName: "TEXT"), "5") == "WHERE \"code\" = '5'")
    }

    private var castingDialect: SQLDialectDescriptor {
        SQLDialectDescriptor(
            identifierQuote: "\"", keywords: [], functions: [], dataTypes: [],
            likeEscapeStyle: .explicit, caseSensitivityStyle: .ilikeOperator, textCastTypeName: "TEXT"
        )
    }

    // PostgreSQL 17 and DuckDB 1.5: `numeric ~~* unknown`, `lower(uuid)` and `~~(INTEGER, ...)` do not exist.
    @Test("Pattern and case-folded matches read a non-character column as text")
    func nonCharacterColumnIsCastForPatterns() {
        let uuid = ColumnInfo(name: "u", typeName: "uuid")
        let dialect = castingDialect
        #expect(engineClause(.postgresql, uuid, "a0", op: .contains, dialect: dialect)
            == "WHERE CAST(\"u\" AS TEXT) ILIKE '%a0%' ESCAPE '!'")
        #expect(engineClause(.postgresql, uuid, "A0", isCaseSensitive: false, dialect: dialect)
            == "WHERE LOWER(CAST(\"u\" AS TEXT)) = LOWER('A0')")
        #expect(engineClause(.postgresql, uuid, "A0", dialect: dialect) == "WHERE \"u\" = 'A0'")
        #expect(engineClause(.postgresql, ColumnInfo(name: "mood", typeName: "USER-DEFINED"), "a, b", op: .in,
                             isCaseSensitive: false, dialect: dialect)
            == "WHERE LOWER(CAST(\"mood\" AS TEXT)) IN (LOWER('a'), LOWER('b'))")
        #expect(engineClause(.postgresql, ColumnInfo(name: "n", typeName: "numeric"), "5", op: .startsWith, dialect: dialect)
            == "WHERE CAST(\"n\" AS TEXT) ILIKE '5%' ESCAPE '!'")
    }

    @Test("Match Case off compares a number, boolean or bit column as itself and still folds a pattern")
    func noCaseColumnsAreNotFolded() {
        let dialect = castingDialect
        let price = ColumnInfo(name: "price", typeName: "numeric(10,2)")
        #expect(engineClause(.postgresql, price, "5.5", isCaseSensitive: false, dialect: dialect) == "WHERE \"price\" = '5.5'")
        #expect(engineClause(.postgresql, price, "5.5, 6", op: .in, isCaseSensitive: false, dialect: dialect)
            == "WHERE \"price\" IN ('5.5', '6')")
        #expect(engineClause(.postgresql, ColumnInfo(name: "b", typeName: "bit"), "1", isCaseSensitive: false, dialect: dialect)
            == "WHERE \"b\" = '1'")
        #expect(engineClause(.postgresql, ColumnInfo(name: "f", typeName: "boolean"), "TRUE", op: .contains,
                             isCaseSensitive: false, dialect: dialect)
            == "WHERE CAST(\"f\" AS TEXT) ILIKE '%TRUE%' ESCAPE '!'")
    }

    @Test("A character column keeps its own operand", arguments: ["character varying", "text", "citext", "bpchar", "name"])
    func characterColumnIsNotCast(typeName: String) {
        let column = ColumnInfo(name: "c", typeName: typeName)
        #expect(engineClause(.postgresql, column, "x", op: .contains, dialect: castingDialect)
            == "WHERE \"c\" ILIKE '%x%' ESCAPE '!'")
    }

    @Test("Engine type names map to a column kind", arguments: [
        ("bit(3)", DatabaseType.postgresql, PluginColumnKind.text),
        ("boolean", .postgresql, .text),
        ("real", .postgresql, .text),
        ("bigint", .postgresql, .integer),
        ("smallint", .redshift, .integer),
        ("BIT", .duckdb, .text),
        ("BOOLEAN", .duckdb, .integer),
        ("FLOAT", .duckdb, .decimal),
        ("bit(8)", .mysql, .integer),
        ("bit", .mssql, .integer),
        ("REAL", .sqlite, .decimal)
    ])
    func engineTypeNameKind(typeName: String, type: DatabaseType, kind: PluginColumnKind) {
        #expect(FilterColumnKind.kind(forTypeName: typeName, databaseType: type) == kind)
    }

    @Test("A key value takes the literal its column's engine compares exactly")
    func keyLiterals() {
        #expect(FilterColumnKind.keyLiteral("5", column: nil, databaseType: .postgresql) == .text("5"))
        #expect(FilterColumnKind.keyLiteral("5", column: ColumnInfo(name: "id", typeName: "int"), databaseType: .postgresql)
            == .number("5"))
        #expect(FilterColumnKind.keyLiteral("5", column: ColumnInfo(name: "b", typeName: "bit(8)"), databaseType: .mysql)
            == .number("5"))
        #expect(FilterColumnKind.keyLiteral("5", column: nil, databaseType: .sqlite) == .numberOrText("5"))
        #expect(FilterColumnKind.keyLiteral("05", column: nil, databaseType: .sqlite) == .text("05"))
    }
}
