import Testing
import Foundation
@testable import TableProQuery
@testable import TableProModels
@testable import TableProPluginKit

@Suite("FilterSQLGenerator Tests")
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
}
