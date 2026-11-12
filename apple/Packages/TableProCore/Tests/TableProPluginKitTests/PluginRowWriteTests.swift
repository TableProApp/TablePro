import Foundation
import TableProPluginKit
import Testing

struct PluginRowWriteTests {
    @Test("A write built without a count leaves it to the host")
    func countDefaultsToNil() {
        let lookup = PluginRowLookup(query: "SELECT 1", parameters: [], rowCount: 1, pinsRows: false)

        #expect(PluginRowWrite(statement: "DELETE", rowIndices: [0]).expectedRowCount == nil)
        #expect(PluginRowWrite(statement: "DELETE", rowIndices: [0], lookup: lookup).expectedRowCount == nil)
    }

    @Test("A write keeps the count and the lookup its driver gave it")
    func keepsTheDriversCount() {
        let lookup = PluginRowLookup(query: "SELECT 1", parameters: [], rowCount: 1, pinsRows: false)
        let write = PluginRowWrite(
            statement: "UPDATE t SET a = ? WHERE id = ?",
            parameters: [.text("1"), .text("2")],
            rowIndices: [3],
            lookup: lookup,
            expectedRowCount: 1
        )

        #expect(write.expectedRowCount == 1)
        #expect(write.lookup == lookup)
        #expect(write.rowIndices == [3])
    }
}
