import Foundation
@testable import TablePro
import Testing

struct ConnectionURLFilterTests {
    private func filter(_ url: String) -> ConnectionURLFilter? {
        guard case .success(let parsed) = ConnectionURLParser.parse(url) else {
            Issue.record("Expected \(url) to parse")
            return nil
        }
        return parsed.filter
    }

    @Test("Each raw SQL alias is read as a condition", arguments: ["condition", "raw", "query"])
    func rawAliases(_ name: String) {
        let url = "mysql://root@127.0.0.1/shop?table=orders&\(name)=total+%3E+1000"
        #expect(filter(url) == .condition("total > 1000"))
    }

    @Test("A condition overrides the column filter")
    func conditionWins() {
        let url = "postgresql://u@localhost/db?table=t&column=status&value=active&condition=id%3D1"
        #expect(filter(url) == .condition("id=1"))
    }

    @Test("Column, operation and value make a column filter")
    func columnFilter() {
        let url = "postgresql://u@localhost/db?table=t&column=status&operation=contains&value=pending+review"
        let parsed = filter(url)
        #expect(parsed == .column(name: "status", operation: "contains", value: "pending review"))
        #expect(parsed?.displayText == "status contains pending review")
    }

    @Test("A filter on a link that opens no table is not applied, so there is none")
    func noTableNoFilter() {
        #expect(filter("postgresql://u@localhost/db?condition=1%3D1") == nil)
        #expect(filter("postgresql://u@localhost/db?column=status&value=a") == nil)
    }

    @Test("A view link carries its filter too")
    func viewFilter() {
        #expect(filter("mysql://root@localhost/shop?view=v&raw=a%3D1") == .condition("a=1"))
    }

    @Test("An SSH link carries its filter")
    func sshFilter() {
        let url = "mysql+ssh://ops@bastion.example.com/root@127.0.0.1/shop?table=orders&raw=id%3D1"
        #expect(filter(url) == .condition("id=1"))
    }

    @Test("A link with a table and no filter has none")
    func tableOnly() {
        #expect(filter("mysql://root@localhost/shop?table=orders") == nil)
    }

    @Test("The condition is shown whole")
    func conditionShownWhole() {
        let condition = String(repeating: "a", count: 400) + " OR 1=1"
        #expect(ConnectionURLFilter.condition(condition).displayText == condition)
    }

    @Test("A condition becomes one applied raw SQL filter carrying the same text")
    func conditionFilterState() throws {
        let state = ConnectionURLFilter.condition("total > 1000").filterState
        let filter = try #require(state.filters.first)
        #expect(state.filters.count == 1)
        #expect(state.commit == .all)
        #expect(state.isVisible)
        #expect(filter.isRawSQL)
        #expect(filter.rawSQL == "total > 1000")
    }

    @Test("A column filter keeps its column and value and maps the operation")
    func columnFilterState() throws {
        let cases: [(operation: String, expected: FilterOperator)] = [
            ("contains", .contains), (">=", .greaterOrEqual), ("Is Null", .isNull), ("unknown", .contains)
        ]
        for (operation, expected) in cases {
            let state = ConnectionURLFilter.column(name: "status", operation: operation, value: "a").filterState
            let filter = try #require(state.filters.first)
            #expect(filter.columnName == "status", "\(operation)")
            #expect(filter.value == "a", "\(operation)")
            #expect(filter.filterOperator == expected, "\(operation)")
            #expect(state.commit == .all, "\(operation)")
        }
    }

    @Test("A column filter without an operation compares for equality")
    func columnFilterDefaultsToEqual() throws {
        let state = ConnectionURLFilter.column(name: "status", operation: nil, value: nil).filterState
        let filter = try #require(state.filters.first)
        #expect(filter.filterOperator == .equal)
        #expect(filter.value.isEmpty)
    }
}
