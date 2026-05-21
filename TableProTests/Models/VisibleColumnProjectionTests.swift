import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("VisibleColumnProjection")
struct VisibleColumnProjectionTests {
    private let columns = ["id", "name", "email"]
    private let columnTypes: [ColumnType] = [
        .integer(rawType: "INT"),
        .text(rawType: "VARCHAR"),
        .text(rawType: "VARCHAR"),
    ]
    private let values: [PluginCellValue] = [.text("1"), .text("Alice"), .text("alice@test.com")]

    @Test("Nil indices passes columns through unchanged")
    func identityColumns() {
        let projection = VisibleColumnProjection.identity
        #expect(projection.columns(columns) == columns)
        #expect(projection.values(values) == values)
    }

    @Test("Hidden column dropped from columns, types, and values")
    func dropsHiddenColumn() {
        let projection = VisibleColumnProjection(indices: [0, 2])
        #expect(projection.columns(columns) == ["id", "email"])
        #expect(projection.columnTypes(columnTypes) == [.integer(rawType: "INT"), .text(rawType: "VARCHAR")])
        #expect(projection.values(values) == [.text("1"), .text("alice@test.com")])
    }

    @Test("Reordered indices reorder columns and values together")
    func respectsReorder() {
        let projection = VisibleColumnProjection(indices: [2, 0, 1])
        #expect(projection.columns(columns) == ["email", "id", "name"])
        #expect(projection.values(values) == [.text("alice@test.com"), .text("1"), .text("Alice")])
    }

    @Test("Out-of-range value index yields NULL to keep alignment")
    func shortRowFillsNull() {
        let projection = VisibleColumnProjection(indices: [0, 1, 2])
        let shortRow: [PluginCellValue] = [.text("1")]
        #expect(projection.values(shortRow) == [.text("1"), .null, .null])
    }

    @Test("Empty indices produces empty projection")
    func emptyIndices() {
        let projection = VisibleColumnProjection(indices: [])
        #expect(projection.columns(columns).isEmpty)
        #expect(projection.values(values).isEmpty)
    }
}
