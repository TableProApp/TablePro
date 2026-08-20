//
//  MultiRowEditStateJsonTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("MultiRowEditState JSON change detection")
@MainActor
struct MultiRowEditStateJsonTests {
    private func makeState(value: String, type: ColumnType, column: String = "data") -> MultiRowEditState {
        let state = MultiRowEditState()
        state.configure(
            selectedRowIndices: [0],
            allRows: [[value]],
            columns: [column],
            columnTypes: [type]
        )
        return state
    }

    @Test("Reformatting a JSONB field does not mark it changed")
    func jsonReformatNotDirty() {
        let original = "{\"b\":1,\"a\":2}"
        let state = makeState(value: original, type: .json(rawType: "jsonb"))
        state.updateField(at: 0, value: JsonReindenter.reindent(original))
        #expect(state.fields[0].hasEdit == false)
        #expect(state.hasEdits == false)
    }

    @Test("Reordering keys is treated as a real change")
    func jsonKeyReorderIsChange() {
        let state = makeState(value: "{\"a\":1,\"b\":2}", type: .json(rawType: "jsonb"))
        state.updateField(at: 0, value: "{\"b\":2,\"a\":1}")
        #expect(state.fields[0].hasEdit == true)
    }

    @Test("A real JSON value change stores the normalized form")
    func jsonContentChangeStoresNormalized() {
        let state = makeState(value: "{\"a\":1}", type: .json(rawType: "jsonb"))
        state.updateField(at: 0, value: "{\n  \"a\": 2\n}")
        #expect(state.fields[0].hasEdit == true)
        #expect(state.fields[0].pendingValue == "{\"a\":2}")
    }

    @Test("Editing back to the original content clears the pending change")
    func jsonRevertClearsChange() {
        let original = "{\"a\":1}"
        let state = makeState(value: original, type: .json(rawType: "jsonb"))
        state.updateField(at: 0, value: "{\"a\":2}")
        #expect(state.fields[0].hasEdit == true)
        state.updateField(at: 0, value: JsonReindenter.reindent(original))
        #expect(state.fields[0].hasEdit == false)
    }

    @Test("Large integers survive a JSONB edit without precision loss")
    func jsonLargeIntegerPreserved() {
        let state = makeState(value: "{\"id\":1}", type: .json(rawType: "jsonb"))
        state.updateField(at: 0, value: "{\"id\":9007199254740993}")
        #expect(state.fields[0].pendingValue == "{\"id\":9007199254740993}")
    }

    @Test("A text column holding JSON is compared semantically")
    func textColumnJsonSemantics() {
        let original = "{\"a\":1,\"b\":2}"
        let state = makeState(value: original, type: .text(rawType: "text"), column: "payload")
        #expect(state.fields[0].isJson == true)
        state.updateField(at: 0, value: JsonReindenter.reindent(original))
        #expect(state.fields[0].hasEdit == false)
    }

    @Test("Non-JSON fields use exact string comparison")
    func nonJsonExactComparison() {
        let state = makeState(value: "hello", type: .text(rawType: "varchar"), column: "name")
        #expect(state.fields[0].isJson == false)
        state.updateField(at: 0, value: "hello ")
        #expect(state.fields[0].hasEdit == true)
        state.updateField(at: 0, value: "hello")
        #expect(state.fields[0].hasEdit == false)
    }
}
