import TableProPluginKit
import Testing
@testable import TablePro

@Suite("Export format filtering for Redis")
struct ExportModelsRedisTests {

    @Test("ExportObjectItem supports optionValues for generic per-object options")
    func tableItemOptionValues() {
        let item = ExportObjectItem(name: "keys", kind: .table, isSelected: true, optionValues: [true, false])
        #expect(item.optionValues.count == 2)
        #expect(item.optionValues[0] == true)
        #expect(item.optionValues[1] == false)
    }

    @Test("ExportObjectItem defaults to empty optionValues")
    func tableItemDefaultOptionValues() {
        let item = ExportObjectItem(name: "keys", kind: .table)
        #expect(item.optionValues.isEmpty)
    }

    @Test("ExportDatabaseItem tracks selected tables correctly")
    func databaseItemSelection() {
        let tables = [
            ExportObjectItem(name: "keys", kind: .table, isSelected: true),
            ExportObjectItem(name: "sets", kind: .table, isSelected: false),
        ]
        let db = ExportDatabaseItem(name: "0", objects: tables)
        #expect(db.selectedCount == 1)
        #expect(db.selectedObjects.map(\.name) == ["keys"])
    }
}
