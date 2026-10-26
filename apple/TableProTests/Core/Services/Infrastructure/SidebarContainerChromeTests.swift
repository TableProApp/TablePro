import AppKit
@testable import TablePro
import TableProTestSupport
import Testing

/// The filter field belongs to the window, not to the connection under it. It used to be hidden
/// until a session arrived, so the sidebar was a bare column for the length of every connect and
/// the field appeared alongside the object list.
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

    @MainActor
    private struct FilterHost {
        let controller: SidebarContainerViewController
        let window: NSWindow

        init(state: SharedSidebarState) {
            controller = SidebarContainerViewController()
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 280, height: 600),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            controller.view.frame = NSRect(x: 0, y: 0, width: 280, height: 600)
            window.contentView?.addSubview(controller.view)
            controller.updateSidebarState(state)
        }

        var isFilterEditing: Bool {
            controller.view.firstDescendant(of: NSSearchField.self)?.currentEditor() != nil
        }

        func tearDown() {
            _ = window.makeFirstResponder(nil)
            controller.updateSidebarState(nil)
            controller.view.removeFromSuperview()
        }
    }

    @Test("Focusing the filter on Tables marks a search started, and ending the edit clears it")
    func tablesFocusIsMarkedUntilEditingEnds() {
        let state = SharedSidebarState()
        let host = FilterHost(state: state)
        defer { host.tearDown() }

        host.controller.focusSearchField()
        #expect(host.isFilterEditing)
        #expect(state.isFilterFieldFocused)

        #expect(host.window.makeFirstResponder(nil))
        #expect(!state.isFilterFieldFocused)
    }

    @Test("Focusing the filter on Favorites marks nothing, since that list never reads the all-schema listing")
    func favoritesFocusIsNotMarked() {
        let state = SharedSidebarState()
        state.selectedSidebarTab = .favorites
        let host = FilterHost(state: state)
        defer { host.tearDown() }

        host.controller.focusSearchField()

        #expect(host.isFilterEditing)
        #expect(!state.isFilterFieldFocused)
    }

    @Test("Flipping to Tables while the field edits marks the search, so the first keystroke does not start the listing")
    func flipToTablesMarksTheEditingField() async throws {
        let state = SharedSidebarState()
        state.selectedSidebarTab = .favorites
        let host = FilterHost(state: state)
        defer { host.tearDown() }
        host.controller.focusSearchField()
        #expect(!state.isFilterFieldFocused)

        state.selectedSidebarTab = .tables

        try await waitUntil { state.isFilterFieldFocused }
        #expect(host.isFilterEditing)
    }

    @Test("Flipping to Favorites while the field edits clears the mark Tables set")
    func flipToFavoritesClearsTheMark() async throws {
        let state = SharedSidebarState()
        let host = FilterHost(state: state)
        defer { host.tearDown() }
        host.controller.focusSearchField()
        #expect(state.isFilterFieldFocused)

        state.selectedSidebarTab = .favorites

        try await waitUntil { !state.isFilterFieldFocused }
        #expect(host.isFilterEditing)
    }

    @Test("The focus stays through a rebind to the same connection and leaves with the field for another")
    func focusLeavesWithTheField() {
        let first = SharedSidebarState()
        let second = SharedSidebarState()
        let host = FilterHost(state: first)
        defer { host.tearDown() }
        host.controller.focusSearchField()

        host.controller.updateSidebarState(first)
        #expect(first.isFilterFieldFocused)

        host.controller.updateSidebarState(second)
        #expect(!first.isFilterFieldFocused)
        #expect(!second.isFilterFieldFocused)
    }

    @Test("Losing the session clears the focus the field marked")
    func losingTheSessionClearsTheFocus() {
        let state = SharedSidebarState()
        let host = FilterHost(state: state)
        defer { host.tearDown() }
        host.controller.focusSearchField()
        #expect(state.isFilterFieldFocused)

        host.controller.updateSidebarState(nil)

        #expect(!state.isFilterFieldFocused)
    }
}
