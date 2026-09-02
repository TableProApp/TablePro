//
//  ColumnJumpViewModelTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@MainActor
struct ColumnJumpViewModelTests {
    private func entry(_ name: String, dataIndex: Int, position: Int?, hidden: Bool = false) -> GridColumnEntry {
        GridColumnEntry(name: name, dataIndex: dataIndex, typeName: "TEXT", position: position, isHidden: hidden)
    }

    @Test("An empty query lists presented columns by position and hidden ones after")
    func emptyQueryOrder() {
        let viewModel = ColumnJumpViewModel(entries: [
            entry("third", dataIndex: 0, position: 3),
            entry("first", dataIndex: 1, position: 1),
            entry("gone", dataIndex: 2, position: nil, hidden: true),
            entry("second", dataIndex: 3, position: 2)
        ])

        #expect(viewModel.matches.map(\.entry.name) == ["first", "second", "third", "gone"])
        #expect(viewModel.matches.allSatisfy { $0.matchedIndices.isEmpty })
        #expect(viewModel.selectedId == "column-1")
    }

    @Test("A query ranks fuzzy matches and reports the characters it hit")
    func fuzzyRanking() {
        let viewModel = ColumnJumpViewModel(
            entries: [
                entry("customer_id", dataIndex: 0, position: 1),
                entry("created_at", dataIndex: 1, position: 2),
                entry("id", dataIndex: 2, position: 3)
            ],
            initialQuery: "crat"
        )

        #expect(viewModel.matches.map(\.entry.name) == ["created_at"])
        #expect(
            viewModel.matches.first?.matchedIndices == [0, 1, 8, 9],
            "the matcher prefers the `_at` boundary over the consecutive `at`, and the row must bold what it chose"
        )
        #expect(viewModel.selectedEntry?.name == "created_at")
    }

    @Test("The list opens on the column under the cell cursor")
    func cursorPreselection() {
        let viewModel = ColumnJumpViewModel(
            entries: [
                entry("id", dataIndex: 0, position: 1),
                entry("name", dataIndex: 1, position: 2),
                entry("email", dataIndex: 2, position: 3)
            ],
            cursorColumnIndex: 2
        )

        #expect(viewModel.selectedId == "column-2")
    }

    @Test("A new query moves the selection to its best match, a repeated one keeps it")
    func selectionFollowsTheQuery() {
        let viewModel = ColumnJumpViewModel(entries: [
            entry("created_at", dataIndex: 0, position: 1),
            entry("credit", dataIndex: 1, position: 2),
            entry("crumbs", dataIndex: 2, position: 3)
        ])

        viewModel.searchText = "cr"
        viewModel.moveSelection(by: 1)
        let moved = viewModel.selectedId
        #expect(moved != viewModel.matches.first?.id)

        viewModel.searchText = "cr "
        #expect(viewModel.selectedId == moved, "trailing whitespace ranks the same rows, so the selection stays")

        viewModel.searchText = "cre"
        #expect(viewModel.matches.map(\.entry.name) == ["credit", "created_at"])
        #expect(viewModel.selectedId == viewModel.matches.first?.id)
    }

    @Test("Moving the selection clamps to the list")
    func moveSelectionClamps() {
        let viewModel = ColumnJumpViewModel(entries: [
            entry("a", dataIndex: 0, position: 1),
            entry("b", dataIndex: 1, position: 2)
        ])

        viewModel.moveSelection(by: -5)
        #expect(viewModel.selectedId == "column-0")
        viewModel.moveSelection(by: 50)
        #expect(viewModel.selectedId == "column-1")
    }

    @Test("The list height budgets one row for no matches and caps at the visible maximum")
    func listHeight() {
        let entries = (0..<20).map { entry("c\($0)", dataIndex: $0, position: $0 + 1) }
        let viewModel = ColumnJumpViewModel(entries: entries)

        #expect(viewModel.listHeight(rowHeight: 10, maxVisibleRows: 9) == 90)
        viewModel.searchText = "zzz"
        #expect(viewModel.matches.isEmpty)
        #expect(viewModel.listHeight(rowHeight: 10, maxVisibleRows: 9) == 10)
        #expect(viewModel.presentedColumnCount == 20)
    }
}
