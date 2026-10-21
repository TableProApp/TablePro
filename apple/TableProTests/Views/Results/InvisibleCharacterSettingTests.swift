//
//  InvisibleCharacterSettingTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

extension GlobalStateSuites {
    @MainActor
    struct InvisibleCharacterSettingTests {
        @Test(
            "A field holding an invisible character changes editor when the setting changes under it",
            .appSettings { $0.dataGrid.showInvisibleCharacters = true }
        )
        func editorFollowsTheSetting() async throws {
            let state = MultiRowEditState()
            state.configure(
                selectedRowIndices: [0],
                allRows: [["abc\u{200B}", "plain"]],
                columns: ["marked", "plain"],
                columnTypes: [.text(rawType: "VARCHAR(20)"), .text(rawType: "VARCHAR(20)")]
            )
            #expect(state.fields[0].resolvedEditor == .multiLine)
            #expect(state.fields[1].resolvedEditor == .singleLine)

            AppSettingsManager.shared.dataGrid.showInvisibleCharacters = false
            try await waitUntil { state.fields[0].resolvedEditor == .singleLine }
            #expect(state.fields[1].resolvedEditor == .singleLine)

            AppSettingsManager.shared.dataGrid.showInvisibleCharacters = true
            try await waitUntil { state.fields[0].resolvedEditor == .multiLine }
        }

        @Test(
            "Find matches a lone CR as the space the cell shows while marks are off",
            .appSettings { $0.dataGrid.showInvisibleCharacters = false }
        )
        func findReadsTheUnmarkedText() {
            let coordinator = makeCoordinator(values: ["a\rb"])

            #expect(coordinator.runFind(term: "a b").count == 1)
        }

        @Test(
            "Find does not read a marked CR as a space",
            .appSettings { $0.dataGrid.showInvisibleCharacters = true }
        )
        func findReadsTheMarkedText() {
            let coordinator = makeCoordinator(values: ["a\rb"])

            #expect(coordinator.runFind(term: "a b").isEmpty)
            #expect(coordinator.runFind(term: "b").count == 1)
        }

        private func makeCoordinator(values: [String]) -> TableViewCoordinator {
            let coordinator = TableViewCoordinator(
                changeManager: AnyChangeManager(DataChangeManager()),
                isEditable: true,
                selectedRowIndices: .constant([]),
                delegate: nil,
                layoutPersister: InMemoryColumnLayoutStore()
            )
            let rows = ContiguousArray(values.enumerated().map { index, value in
                Row(id: .existing(index), values: [PluginCellValue.text(value)])
            })
            var captured = TableRows(rows: rows, columns: ["v"], columnTypes: [.text(rawType: nil)])
            coordinator.tableRowsProvider = { captured }
            coordinator.tableRowsMutator = { (mutation: (inout TableRows) -> Delta) in mutation(&captured) }
            coordinator.updateCache()
            return coordinator
        }
    }
}
