import AppKit
@testable import TablePro
import Testing

/// The filter field belongs to the window, not to the connection under it. It used to be hidden
/// until a session arrived, so the sidebar was a bare column for the length of every connect and
/// the field appeared alongside the object list.
@Suite("Sidebar container chrome")
@MainActor
struct SidebarContainerChromeTests {
    @Test("The filter field stands before a connection is up, dimmed")
    func filterStandsDisabledWithNoSession() {
        let controller = SidebarContainerViewController()
        controller.loadView()

        controller.updateSidebarState(nil)

        #expect(!controller.isFilterEnabled)
    }

    /// `syncFromState` is the only writer of the field's text and it cannot run without a state, so
    /// a field left standing would keep the filter the previous connection was showing.
    @Test("Losing the session clears the filter it was showing")
    func filterTextDoesNotOutliveItsConnection() {
        let controller = SidebarContainerViewController()
        controller.loadView()
        let state = SharedSidebarState.forConnection(UUID())
        state.searchText = "orders"

        controller.updateSidebarState(state)
        controller.updateSidebarState(nil)

        #expect(controller.filterText.isEmpty)
        #expect(!controller.isFilterEnabled)
    }

    @Test("A session enables the field it was standing dimmed for")
    func sessionEnablesTheFilter() {
        let controller = SidebarContainerViewController()
        controller.loadView()

        controller.updateSidebarState(SharedSidebarState.forConnection(UUID()))

        #expect(controller.isFilterEnabled)
    }
}
