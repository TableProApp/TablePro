//
//  JsonFieldEditingModelTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

// #3051: adopting the store's restated value looped the editor at 100% CPU (6,944 body evaluations in 30 s).
@MainActor
struct JsonFieldEditingModelTests {
    private static func makeState(value: String, type: ColumnType) -> MultiRowEditState {
        let state = MultiRowEditState()
        state.configure(
            rowIDs: [.existing(0)],
            allRows: [[value]],
            columns: ["payload"],
            columnTypes: [type]
        )
        return state
    }

    // Asserted directly: displayText and lastSynced match at every exit, so a re-publish loop would always look converged.
    private static func adoptsRestatement(
        _ model: inout JsonFieldEditingModel,
        from state: MultiRowEditState
    ) -> Bool {
        model.received(state.currentText(at: 0))
    }

    @Test("A keystroke survives the round trip and the store's echo is refused")
    func keystrokeSettles() {
        let original = "{\"a\":1}"
        let state = Self.makeState(value: original, type: .json(rawType: "jsonb"))
        var model = JsonFieldEditingModel(storedValue: original)
        #expect(model.displayText == JsonReindenter.reindent(original))

        let typed = "{\n  \"a\": 2\n}"
        let published = model.typed(typed)
        #expect(published == typed)
        state.updateField(at: 0, value: published)

        let adopted = Self.adoptsRestatement(&model, from: state)
        #expect(!adopted, "the store answers with the compact form of what was just typed")
        #expect(model.displayText == typed, "the editor keeps its layout, not the compact echo")
        #expect(state.fields[0].pendingValue == "{\"a\":2}")
    }

    // Halfway through typing a value, where JsonReindenter's parse-failure fallback used to make the two sides disagree.
    @Test("A transiently invalid document keeps every keystroke")
    func invalidIntermediateSettles() {
        let original = "{\"a\": 1}"
        let state = Self.makeState(value: original, type: .text(rawType: "text"))
        var model = JsonFieldEditingModel(storedValue: original)

        for typed in ["{\"a\": 1,", "{\"a\": 1, \"", "{\"a\": 1, \"b\"", "{\"a\": 1, \"b\": 2}"] {
            if let published = model.typed(typed) {
                state.updateField(at: 0, value: published)
            }
            let adopted = Self.adoptsRestatement(&model, from: state)
            #expect(!adopted, "the store's restatement was adopted on \(typed)")
            #expect(model.displayText == typed, "the keystroke must survive")
        }
    }

    // The store drops a pending value equal to the stored one, so the binding answers with the original: still our own echo.
    @Test("Editing back to the stored value does not bounce")
    func revertToOriginalSettles() {
        let original = "{\"a\":1}"
        let state = Self.makeState(value: original, type: .json(rawType: "jsonb"))
        var model = JsonFieldEditingModel(storedValue: original)

        state.updateField(at: 0, value: model.typed("{\n  \"a\": 2\n}"))
        #expect(state.fields[0].hasEdit)

        state.updateField(at: 0, value: model.typed(JsonReindenter.reindent(original)))
        #expect(!state.fields[0].hasEdit)
        let adopted = Self.adoptsRestatement(&model, from: state)
        #expect(!adopted)
    }

    @Test("The editor's own write is never adopted back")
    func ownWriteIsNotAdopted() {
        var model = JsonFieldEditingModel(storedValue: "{\"a\":1}")
        let typed = "{\n  \"a\": 2\n}"
        let published = model.typed(typed)
        #expect(published == typed)
        let adopted = model.received("{\"a\":2}")
        #expect(!adopted, "the compact echo of what was just typed")
        #expect(model.displayText == typed, "the caret's layout must not be rewritten")
    }

    @Test("A value the editor did not write is adopted, and is not published back")
    func externalChangeIsAdopted() {
        var model = JsonFieldEditingModel(storedValue: "{\"a\":1}")
        let adopted = model.received("{\"b\":2}")
        #expect(adopted)
        #expect(model.displayText == JsonReindenter.reindent("{\"b\":2}"))
        // Arrived compact and displays laid out; republishing it would stage an edit the user never made.
        let republished = model.typed(model.displayText)
        #expect(republished == nil, "adopting is not an edit")
    }

    // Set NULL, DEFAULT and EMPTY all empty the text; publishing that back would clear the state the user asked for.
    @Test("An emptied field is adopted once and not published back")
    func emptiedFieldIsNotRepublished() {
        var model = JsonFieldEditingModel(storedValue: "{\"a\":1}")
        let adopted = model.received("")
        #expect(adopted)
        #expect(model.displayText.isEmpty)
        let republished = model.typed(model.displayText)
        #expect(republished == nil, "adopting is not an edit")
    }

    @Test("Text that does not parse is compared exactly, not reported equal")
    func unparseableComparesExactly() {
        var model = JsonFieldEditingModel(storedValue: "{\"a\": ")
        #expect(model.displayText == "{\"a\": ", "text the parser refuses is shown as it is")
        let adopted = model.received("{\"b\": ")
        #expect(adopted)
    }
}
