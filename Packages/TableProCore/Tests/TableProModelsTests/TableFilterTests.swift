import Foundation
@testable import TableProModels
import Testing

@Suite("TableFilter Tests")
struct TableFilterTests {
    @Test("Valid filter with value")
    func validFilterWithValue() {
        let filter = TableFilter(columnName: "name", filterOperator: .equal, value: "test")
        #expect(filter.isValid)
    }

    @Test("Invalid filter with empty column")
    func invalidEmptyColumn() {
        let filter = TableFilter(columnName: "", filterOperator: .equal, value: "test")
        #expect(!filter.isValid)
    }

    @Test("Invalid filter with empty value")
    func invalidEmptyValue() {
        let filter = TableFilter(columnName: "name", filterOperator: .equal, value: "")
        #expect(!filter.isValid)
    }

    @Test("isNull does not require value")
    func isNullNoValue() {
        let filter = TableFilter(columnName: "name", filterOperator: .isNull, value: "")
        #expect(filter.isValid)
    }

    @Test("isNotNull does not require value")
    func isNotNullNoValue() {
        let filter = TableFilter(columnName: "name", filterOperator: .isNotNull, value: "")
        #expect(filter.isValid)
    }

    @Test("Between requires both values")
    func betweenRequiresBothValues() {
        let incomplete = TableFilter(
            columnName: "age",
            filterOperator: .between,
            value: "10",
            secondValue: ""
        )
        #expect(!incomplete.isValid)

        let complete = TableFilter(
            columnName: "age",
            filterOperator: .between,
            value: "10",
            secondValue: "20"
        )
        #expect(complete.isValid)
    }

    @Test("Raw SQL filter validation")
    func rawSQLFilter() {
        let valid = TableFilter(
            columnName: TableFilter.rawSQLColumn,
            rawSQL: "age > 10"
        )
        #expect(valid.isValid)

        let invalid = TableFilter(
            columnName: TableFilter.rawSQLColumn,
            rawSQL: ""
        )
        #expect(!invalid.isValid)

        let nilSQL = TableFilter(
            columnName: TableFilter.rawSQLColumn,
            rawSQL: nil
        )
        #expect(!nilSQL.isValid)
    }

    @Test("Codable round-trip")
    func codableRoundTrip() throws {
        let original = TableFilter(
            columnName: "email",
            filterOperator: .contains,
            value: "test@example.com",
            isEnabled: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TableFilter.self, from: data)
        #expect(decoded.columnName == original.columnName)
        #expect(decoded.filterOperator == original.filterOperator)
        #expect(decoded.value == original.value)
        #expect(decoded.isEnabled == original.isEnabled)
    }
}
