//
//  TableViewCoordinatorFindTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("TableViewCoordinator find over binary columns")
@MainActor
struct TableViewCoordinatorFindTests {
    /// Row 0 decodes under Text, row 1 does not and falls back to hex `0x89504E47`.
    private func makeCoordinator(format: ValueDisplayFormat?) -> TableViewCoordinator {
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: FakeFindLayoutPersister()
        )
        let rows: ContiguousArray<Row> = [
            Row(id: .existing(0), values: [.bytes(Data("signup".utf8))]),
            Row(id: .existing(1), values: [.bytes(Data([0x89, 0x50, 0x4E, 0x47]))]),
        ]
        var captured = TableRows(
            rows: rows,
            columns: ["payload"],
            columnTypes: [.blob(rawType: "VARBINARY(255)")]
        )
        coordinator.tableRowsProvider = { captured }
        coordinator.tableRowsMutator = { (mutation: (inout TableRows) -> Void) in mutation(&captured) }
        coordinator.updateCache()
        coordinator.updateDisplayFormats([format])
        return coordinator
    }

    @Test("a binary column showing text is searched on the text")
    func binaryTextColumnIsSearched() {
        let coordinator = makeCoordinator(format: .text)

        let matches = coordinator.runFind(term: "signup")

        #expect(matches.count == 1)
        #expect(matches.first?.displayRow == 0)
    }

    @Test("a cell that fell back to hex is not searched on that hex")
    func hexFallbackCellIsNotSearched() {
        let coordinator = makeCoordinator(format: .text)

        #expect(coordinator.runFind(term: "8950").isEmpty)
        #expect(coordinator.runFind(term: "0x89504E47").isEmpty)
    }

    @Test("a binary column left on raw is not searched at all")
    func rawBinaryColumnIsNotSearched() {
        let coordinator = makeCoordinator(format: nil)

        #expect(coordinator.runFind(term: "signup").isEmpty)
        #expect(coordinator.runFind(term: "8950").isEmpty)
    }
}

private final class FakeFindLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }

    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}

    func clear(for key: ColumnLayoutTableKey) {}
}
