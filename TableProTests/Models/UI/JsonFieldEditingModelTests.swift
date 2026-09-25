//
//  JsonFieldEditingModelTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

/// The regression suite for #3051.
///
/// The editor and the store are two mirrors of one value, and the hang was a fixpoint between
/// them: one keystroke produced 6,944 body evaluations in 30 seconds at 100% CPU, and the typed
/// character was thrown away. What catches it is ``adoptsRestatement``: the store always answers
/// with a different string than the editor holds, and adopting that answer is the bug.
@MainActor
struct JsonFieldEditingModelTests {
    private static func makeState(value: String, type: ColumnType) -> MultiRowEditState {
        let state = MultiRowEditState()
        state.configure(
            selectedRowIndices: [0],
            allRows: [[value]],
            columns: ["payload"],
            columnTypes: [type]
        )
        return state
    }

    /// Whether the editor adopts the store's restatement of what the editor itself just published.
    ///
    /// This is the whole of #3051 in one question. `MultiRowEditState` stages a compacted form of
    /// the text the editor shows, so the store always answers with a *different string* than the
    /// editor holds. Adopting that answer is what overwrote the keystroke and pushed the overwrite
    /// back, at about 75 rounds a second.
    ///
    /// Asserted directly rather than by looping the pair until it settles: `displayText` and
    /// `lastSynced` are equal at every exit of both entry points, so a loop that re-publishes
    /// `model.displayText` can never take a second turn and would report convergence for any model
    /// at all, including one with the bug.
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

    /// The document is invalid for as long as the user is halfway through typing a value, which is
    /// where `JsonReindenter`'s parse-failure fallback used to make the two sides disagree.
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

    /// The store drops a pending value that matches the stored one again, so the binding answers
    /// with the original. That is still this editor's own echo and must not be adopted.
    @Test("Editing back to the stored value does not bounce")
    func revertToOriginalSettles() {
        let original = "{\"a\":1}"
        let state = Self.makeState(value: original, type: .json(rawType: "jsonb"))
        var model = JsonFieldEditingModel(storedValue: original)

        state.updateField(at: 0, value: model.typed("{\n  \"a\": 2\n}"))
        #expect(state.fields[0].hasEdit)

        state.updateField(at: 0, value: model.typed(JsonReindenter.reindent(original)))
        #expect(!state.fields[0].hasEdit)
        /// The store dropped the pending value, so it now answers with `originalValue`. That is
        /// still this editor's own write coming back and must not be adopted.
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
        /// The adopted value arrived compact and is displayed laid out, so the two differ by more
        /// than nothing. Republishing it would stage an edit the user never made.
        let republished = model.typed(model.displayText)
        #expect(republished == nil, "adopting is not an edit")
    }

    /// Set NULL, Set DEFAULT and Set EMPTY all empty the field's editable text. Adopting that and
    /// then publishing it again would clear the state the user just asked for.
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
