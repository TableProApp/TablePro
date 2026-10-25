//
//  InvisibleCharacterSettingTests.swift
//  TableProTests
//

import AppKit
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
                rowIDs: [.existing(0)],
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
            let (model, owner) = makeModel(values: ["a\rb"])
            defer { withExtendedLifetime(owner) {} }

            #expect(find("a b", in: model).count == 1)
        }

        @Test(
            "Find does not read a marked CR as a space",
            .appSettings { $0.dataGrid.showInvisibleCharacters = true }
        )
        func findReadsTheMarkedText() {
            let (model, owner) = makeModel(values: ["a\rb"])
            defer { withExtendedLifetime(owner) {} }

            #expect(find("a b", in: model).isEmpty)
            #expect(find("b", in: model).count == 1)
        }

        // The model holds its owner weakly, so the caller keeps the owner alive.
        private func makeModel(values: [String]) -> (DataGridModel, GridTestOwner) {
            let rows = TableRows.from(
                queryRows: values.map { [PluginCellValue.text($0)] },
                columns: ["v"],
                columnTypes: [.text(rawType: nil)]
            )
            let owner = GridTestOwner(rows)
            let model = DataGridModel()
            model.dataSource = owner
            model.actions = owner
            owner.model = model
            model.reloadRows()
            return (model, owner)
        }

        private func find(_ term: String, in model: DataGridModel) -> [GridFindState.Match] {
            model.showFind()
            model.find.term = term
            model.findQueryDidChange()
            return model.find.matches
        }
    }
}
