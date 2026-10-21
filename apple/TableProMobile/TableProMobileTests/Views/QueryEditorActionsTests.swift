import Foundation
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

    @Test("A view leaving after another took its place leaves the newer menu actions alone")
    func withdrawKeepsTheNewerOwner() {
        let state = SceneMenuState()
        let first = UUID()
        let second = UUID()
        let actions = QueryEditorActions(
            runTitle: "Run Statement", canRun: true, isExecuting: false,
            run: {}, runAll: {}, stop: {}, clear: {}
        )
        state.publishQueryEditor(actions, from: first)
        state.publishQueryEditor(actions, from: second)
        state.withdrawQueryEditor(first)
        #expect(state.queryEditor != nil)
        state.withdrawQueryEditor(second)
        #expect(state.queryEditor == nil)

        state.publishTabs(ConnectedTabActions { _ in }, from: first)
        state.publishTabs(ConnectedTabActions { _ in }, from: second)
        state.withdrawTabs(first)
        #expect(state.tabs != nil)
        state.withdrawTabs(second)
        #expect(state.tabs == nil)
    }
}

