//
//  MultiRowEditStateInvisibleCharacterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

extension GlobalStateSuites {
    @MainActor
    struct MultiRowEditStateInvisibleCharacterTests {
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
    }
}
