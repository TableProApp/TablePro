// The parameter panel's binding read the tab copy taken when the editor was drawn, so a second
// write before the next render started from the first array and undid the first write.

import Foundation
import SwiftUI
@testable import TablePro
import Testing

@MainActor
struct QueryParameterBindingTests {
    @Test("Two parameter writes before a render both land")
    func secondWriteBuildsOnTheFirst() throws {
        let tabManager = QueryTabManager()
        tabManager.addTab(initialQuery: "SELECT * FROM users WHERE id = :id AND name = :name")
        let tabId = try #require(tabManager.selectedTabId)
        tabManager.mutate(tabId: tabId) { tab in
            tab.content.queryParameters = [
                QueryParameter(name: "id", value: "42"),
                QueryParameter(name: "name", value: "bob")
            ]
        }
        let drawn = try #require(tabManager.selectedTab)
        let parameters = MainEditorContentView.parameterBinding(for: drawn, in: tabManager)

        parameters.wrappedValue[0].value = ""
        parameters.wrappedValue[1].value = ""

        let values = tabManager.tabs.first { $0.id == tabId }?.content.queryParameters.map { $0.value }
        #expect(values == ["", ""])
    }
}
