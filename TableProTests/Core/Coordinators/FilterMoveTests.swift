//
//  FilterMoveTests.swift
//  TableProTests
//

import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Filter Move")
@MainActor
struct FilterMoveTests {
    private static let mysqlDialect = SQLDialectDescriptor(
        identifierQuote: "`", keywords: [], functions: [], dataTypes: [],
        regexSyntax: .regexp, booleanLiteralStyle: .numeric,
        likeEscapeStyle: .implicit, paginationStyle: .limit
    )

    private func makeFilters() -> [TableFilter] {
        [
            TestFixtures.makeTableFilter(column: "name", op: .contains, value: "ana"),
            TestFixtures.makeTableFilter(column: "age", op: .greaterThan, value: "18"),
            TestFixtures.makeTableFilter(column: "id", op: .equal, value: "42"),
        ]
    }

    private func applying(_ move: FilterCoordinator.FilterMove, to filters: [TableFilter]) -> [TableFilter] {
        var moved = filters
        moved.move(fromOffsets: move.source, toOffset: move.destination)
        return moved
    }

    @Test("Dropping a row onto an earlier row takes that row's position")
    func dropOntoEarlierRowTakesItsPosition() throws {
        let filters = makeFilters()

        let move = try #require(
            FilterCoordinator.filterMove(in: filters, moving: filters[2].id, onto: filters[0].id)
        )
        let result = applying(move, to: filters)

        #expect(result.map(\.columnName) == ["id", "name", "age"])
    }

    @Test("Dropping a row onto a later row takes that row's position")
    func dropOntoLaterRowTakesItsPosition() throws {
        let filters = makeFilters()

        let move = try #require(
            FilterCoordinator.filterMove(in: filters, moving: filters[0].id, onto: filters[2].id)
        )
        let result = applying(move, to: filters)

        #expect(result.map(\.columnName) == ["age", "id", "name"])
    }

    @Test("Dropping a row onto itself is a no-op")
    func dropOntoSelfIsNoOp() {
        let filters = makeFilters()

        #expect(FilterCoordinator.filterMove(in: filters, moving: filters[1].id, onto: filters[1].id) == nil)
    }

    @Test("A dragged row that is not in the current filter set is a no-op")
    func unknownDraggedFilterIsNoOp() {
        let filters = makeFilters()

        #expect(FilterCoordinator.filterMove(in: filters, moving: UUID(), onto: filters[0].id) == nil)
        #expect(FilterCoordinator.filterMove(in: filters, moving: filters[0].id, onto: UUID()) == nil)
    }

    @Test("Move up swaps a row with the one above it")
    func moveUpSwapsWithRowAbove() throws {
        let filters = makeFilters()

        let move = try #require(FilterCoordinator.filterMove(in: filters, moving: filters[1].id, direction: .up))
        let result = applying(move, to: filters)

        #expect(result.map(\.columnName) == ["age", "name", "id"])
    }

    @Test("Move down swaps a row with the one below it")
    func moveDownSwapsWithRowBelow() throws {
        let filters = makeFilters()

        let move = try #require(FilterCoordinator.filterMove(in: filters, moving: filters[1].id, direction: .down))
        let result = applying(move, to: filters)

        #expect(result.map(\.columnName) == ["name", "id", "age"])
    }

    @Test("Move up on the first row and move down on the last row are no-ops")
    func moveBeyondBoundsIsNoOp() {
        let filters = makeFilters()

        #expect(FilterCoordinator.filterMove(in: filters, moving: filters[0].id, direction: .up) == nil)
        #expect(FilterCoordinator.filterMove(in: filters, moving: filters[2].id, direction: .down) == nil)
    }

    @Test("Move up and move down on an unknown filter are no-ops")
    func moveUnknownFilterIsNoOp() {
        let filters = makeFilters()

        #expect(FilterCoordinator.filterMove(in: filters, moving: UUID(), direction: .up) == nil)
        #expect(FilterCoordinator.filterMove(in: filters, moving: UUID(), direction: .down) == nil)
    }

    @Test("Moving a row carries every field of the condition unchanged")
    func moveCarriesWholeConditionUnchanged() throws {
        let filters = [
            TestFixtures.makeTableFilter(column: "created_at", op: .between, value: "2024", secondValue: "2025"),
            TestFixtures.makeTableFilter(column: "status", op: .equal, value: "active", isEnabled: false),
            TestFixtures.makeTableFilter(
                column: TableFilter.rawSQLColumn,
                op: .equal,
                value: "",
                rawSQL: "price * quantity > 1000"
            ),
        ]

        let move = try #require(
            FilterCoordinator.filterMove(in: filters, moving: filters[2].id, onto: filters[0].id)
        )
        let result = applying(move, to: filters)

        #expect(result[0] == filters[2])
        #expect(result[1] == filters[0])
        #expect(result[2] == filters[1])
    }

    @Test("Reordering rows does not change which filters are applied")
    func reorderPreservesAppliedFilterSet() throws {
        let filters = makeFilters()
        var state = TabFilterState()
        state.filters = filters
        state.commit = .all

        let move = try #require(
            FilterCoordinator.filterMove(in: filters, moving: filters[2].id, onto: filters[0].id)
        )
        var reordered = state
        reordered.filters = applying(move, to: filters)

        #expect(Set(reordered.appliedFilters) == Set(state.appliedFilters))
    }

    @Test("Reordering rows produces an equivalent WHERE clause under a single logic mode")
    func reorderProducesEquivalentWhereClause() throws {
        let filters = makeFilters()
        let generator = FilterSQLGenerator(dialect: Self.mysqlDialect)

        let move = try #require(
            FilterCoordinator.filterMove(in: filters, moving: filters[2].id, onto: filters[0].id)
        )
        let reordered = applying(move, to: filters)

        for mode in [FilterLogicMode.and, .or] {
            let separator = mode == .and ? " AND " : " OR "
            let original = generator.generateConditions(from: filters, logicMode: mode)
            let moved = generator.generateConditions(from: reordered, logicMode: mode)

            #expect(original != moved)
            #expect(Set(original.components(separatedBy: separator))
                == Set(moved.components(separatedBy: separator)))
        }
    }
}
