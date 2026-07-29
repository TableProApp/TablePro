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

    @Test("including(nil) leaves the projection unchanged")
    func includingNilIndexUnchanged() {
        let projection = VisibleColumnProjection(indices: [0, 2]).including(nil)
        #expect(projection.columns(columns) == ["id", "email"])
    }

    @Test("including on the identity projection stays identity")
    func includingOnIdentityStaysIdentity() {
        #expect(VisibleColumnProjection.identity.including(1).columns(columns) == columns)
    }

    @Test("including an already-present index does not duplicate it")
    func includingPresentIndexNoDuplicate() {
        let projection = VisibleColumnProjection(indices: [0, 2]).including(0)
        #expect(projection.columns(columns) == ["id", "email"])
    }

    @Test("including a missing index appends it")
    func includingMissingIndexAppends() {
        let projection = VisibleColumnProjection(indices: [1, 2]).including(0)
        #expect(projection.columns(columns) == ["name", "email", "id"])
        #expect(projection.values(values) == [.text("Alice"), .text("alice@test.com"), .text("1")])
    }

    @Test("UPDATE keeps the primary key in WHERE even when its column is hidden")
    @MainActor
    func updateRetainsHiddenPrimaryKey() throws {
        let projection = VisibleColumnProjection(indices: [1, 2]).including(0)
        let dialect = SQLDialectDescriptor(identifierQuote: "`", keywords: [], functions: [], dataTypes: [])
        let converter = try SQLRowToStatementConverter(
            tableName: "users",
            columns: projection.columns(columns),
            primaryKeyColumn: "id",
            databaseType: .mysql,
            dialect: dialect
        )
        let result = converter.generateUpdates(rows: [projection.values(values)])
        #expect(result == "UPDATE `users` SET `name` = 'Alice', `email` = 'alice@test.com' WHERE `id` = '1';")
    }
}
