import Foundation
@testable import TablePro
import TableProTabular
import Testing

private func columns(named names: [String]) -> [TabularColumn] {
    names.enumerated().map { index, name in
        TabularColumn(id: TabularColumnID(rawValue: index), name: name, values: ColumnValues(base: .source(index)))
    }
}

struct DataFileColumnNamesTests {
    @Test func repeatedHeadersGetNumberedNames() {
        let names = DataFileColumnNames(columns: columns(named: ["id", "id", "", "id (2)", "id"]))
        #expect(names.displayNames == ["id", "id (2)", "Column 3", "id (2) (2)", "id (3)"])
        #expect(names.id(forName: "id (3)") == TabularColumnID(rawValue: 4))
        #expect(names.name(for: TabularColumnID(rawValue: 3)) == "id (2) (2)")
        #expect(names.index(of: TabularColumnID(rawValue: 2)) == 2)
    }

    // A header repeating `id` 40,000 times froze the main actor for minutes. A quadratic loop takes over 20 minutes on 200,000.
    @Test(.timeLimit(.minutes(1)))
    func aHeaderOfOneRepeatedNameNamesEveryColumnQuickly() {
        let count = 200_000
        let names = DataFileColumnNames(columns: columns(named: Array(repeating: "id", count: count)))
        #expect(names.count == count)
        #expect(names.displayNames.last == "id (\(count))")
        #expect(Set(names.displayNames).count == count)
        #expect(names.index(of: TabularColumnID(rawValue: count - 1)) == count - 1)
    }
}
