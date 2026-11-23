// The panel's binding reads the tab as it was when the view rendered, as the query tab's does, so every write starts
// from those values.

import SwiftUI
@testable import TablePro
import Testing

@MainActor
struct QueryParameterPanelClearAllTests {
    private final class Tab {
        var parameters: [QueryParameter]

        init(_ parameters: [QueryParameter]) {
            self.parameters = parameters
        }
    }

    @Test("Clear All clears every parameter, not only the last one")
    func clearAllClearsEveryValue() {
        let tab = Tab([
            QueryParameter(name: "id", value: "42"),
            QueryParameter(name: "name", value: "bob"),
            QueryParameter(name: "limit", value: "10", type: .integer),
        ])
        let rendered = tab.parameters
        let panel = QueryParameterPanelView(
            parameters: Binding(get: { rendered }, set: { tab.parameters = $0 }),
            onDismiss: {}
        )

        panel.clearAllValues()

        #expect(tab.parameters.map { $0.value } == ["", "", ""])
        #expect(tab.parameters.map { $0.name } == ["id", "name", "limit"])
        #expect(tab.parameters.map { $0.type } == [.string, .string, .integer])
    }
}
