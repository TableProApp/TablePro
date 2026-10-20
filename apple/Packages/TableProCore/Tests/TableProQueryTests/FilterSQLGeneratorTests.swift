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
}
