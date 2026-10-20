@testable import TableProMobile
import Testing

@MainActor
struct QueryEditorActionsTests {
    @Test("The Query menu acts on the editor only while it shows")
    func publishesOnlyWhileShown() {
        #expect(QueryEditorActions.publishes(isOnScreen: true, selectedTab: .query))
        #expect(!QueryEditorActions.publishes(isOnScreen: false, selectedTab: .query))
        #expect(!QueryEditorActions.publishes(isOnScreen: true, selectedTab: .tables))
        #expect(!QueryEditorActions.publishes(isOnScreen: true, selectedTab: .history))
    }
}
