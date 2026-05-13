import TableProPluginKit
import Testing
@testable import TablePro

@Suite("Export format filtering for Redis")
struct ExportModelsRedisTests {

    @Test("ExportTableItem supports optionValues for generic per-table options")
    func tableItemOptionValues() {
        let item = ExportTableItem(name: "keys", type: .table, isSelected: true, optionValues: [true, false])
        #expect(item.optionValues.count == 2)
        #expect(item.optionValues[0] == true)
        #expect(item.optionValues[1] == false)
    }

    @Test("ExportTableItem defaults to empty optionValues")
    func tableItemDefaultOptionValues() {
        let item = ExportTableItem(name: "keys", type: .table)
        #expect(item.optionValues.isEmpty)
    }

    @Test("ExportDatabaseItem tracks selected tables correctly")
    func databaseItemSelection() {
        let tables = [
            ExportTableItem(name: "keys", type: .table, isSelected: true),
            ExportTableItem(name: "sets", type: .table, isSelected: false),
        ]
        let db = ExportDatabaseItem(name: "0", tables: tables)
        #expect(db.selectedCount == 1)
        #expect(db.selectedTables.map(\.name) == ["keys"])
    }
}
