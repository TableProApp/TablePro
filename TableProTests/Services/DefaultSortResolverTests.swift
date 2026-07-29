import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("DefaultSortResolver")
struct DefaultSortResolverTests {
    private let columns = ["id", "name", "created_at"]

    @Test("Primary key behavior with single PK returns PK column")
    func singlePrimaryKey() {
        let state = DefaultSortResolver.resolveSortState(
            behavior: .primaryKey, pluginHint: .useAppDefault,
            primaryKeyColumns: ["id"], allColumns: columns
        )
        #expect(state.columns.count == 1)
        #expect(state.columns.first?.columnIndex == 0)
        #expect(state.columns.first?.direction == .ascending)
        #expect(state.source == .defaultSort)
    }

    @Test("Empty resolved state keeps default source (.user)")
    func emptyStateStaysUserSource() {
        let state = DefaultSortResolver.resolveSortState(
            behavior: .none, pluginHint: .useAppDefault,
            primaryKeyColumns: ["id"], allColumns: columns
        )
        #expect(!state.isSorting)
        #expect(state.source == .user)
    }

    @Test("Primary key behavior with composite PK uses all PK columns in order")
    func compositePrimaryKey() {
        let state = DefaultSortResolver.resolveSortState(
            behavior: .primaryKey, pluginHint: .useAppDefault,
            primaryKeyColumns: ["id", "name"], allColumns: columns
        )
        #expect(state.columns.map(\.columnIndex) == [0, 1])
        #expect(state.columns.allSatisfy { $0.direction == .ascending })
    }

    @Test("Primary key behavior with no PK returns empty sort state")
    func noPrimaryKey() {
        let state = DefaultSortResolver.resolveSortState(
            behavior: .primaryKey, pluginHint: .useAppDefault,
            primaryKeyColumns: [], allColumns: columns
        )
        #expect(!state.isSorting)
    }

    @Test("First column behavior returns column at index 0")
    func firstColumn() {
        let state = DefaultSortResolver.resolveSortState(
            behavior: .firstColumn, pluginHint: .useAppDefault,
            primaryKeyColumns: ["id"], allColumns: columns
        )
        #expect(state.columns.count == 1)
        #expect(state.columns.first?.columnIndex == 0)
    }

    @Test("First column behavior with empty columns returns empty sort state")
    func firstColumnEmpty() {
        let state = DefaultSortResolver.resolveSortState(
            behavior: .firstColumn, pluginHint: .useAppDefault,
            primaryKeyColumns: [], allColumns: []
        )
        #expect(!state.isSorting)
    }

    @Test("None behavior never sorts, even with PK present")
    func noneBehavior() {
        let state = DefaultSortResolver.resolveSortState(
            behavior: .none, pluginHint: .useAppDefault,
            primaryKeyColumns: ["id"], allColumns: columns
        )
        #expect(!state.isSorting)
    }

    @Test("Plugin .suppress hint overrides app behavior")
    func suppressOverridesBehavior() {
        let state = DefaultSortResolver.resolveSortState(
            behavior: .primaryKey, pluginHint: .suppress,
            primaryKeyColumns: ["id"], allColumns: columns
        )
        #expect(!state.isSorting)
    }

    @Test("Plugin .forceColumns hint overrides app behavior")
    func forceColumnsOverridesBehavior() {
        let state = DefaultSortResolver.resolveSortState(
            behavior: .none, pluginHint: .forceColumns(["created_at"]),
            primaryKeyColumns: [], allColumns: columns
        )
        #expect(state.columns.count == 1)
        #expect(state.columns.first?.columnIndex == 2)
    }

    @Test("Force columns filters out names not present in allColumns")
    func forceColumnsFiltersUnknown() {
        let state = DefaultSortResolver.resolveSortState(
            behavior: .none, pluginHint: .forceColumns(["created_at", "missing"]),
            primaryKeyColumns: [], allColumns: columns
        )
        #expect(state.columns.map(\.columnIndex) == [2])
    }

    @Test("Primary key filters out PK names not present in current columns")
    func pkNotInColumns() {
        let state = DefaultSortResolver.resolveSortState(
            behavior: .primaryKey, pluginHint: .useAppDefault,
            primaryKeyColumns: ["hidden_pk"], allColumns: columns
        )
        #expect(!state.isSorting)
    }
}
