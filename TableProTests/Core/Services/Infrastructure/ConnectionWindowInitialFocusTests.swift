import AppKit
import Foundation
@testable import TablePro
import Testing

/// Command W closed the whole connection instead of the current tab in a window nobody had clicked
/// into yet, whether it was restored at launch or opened fresh.
///
/// AppKit gives a window its first responder once, as the window is first placed on screen, and
/// only from the views that exist at that moment. The editor, the grid and the object list are
/// SwiftUI and did not exist yet, so the pick fell to the connections strip's list, which was
/// collapsed to zero width but never hidden. The strip answers Close itself, so Command W took the
/// connection.
@Suite("Connection window initial focus", .serialized)
@MainActor
struct ConnectionWindowInitialFocusTests {
    @Test("A connections strip that has never been shown is not a key view")
    func unshownStripIsNotAKeyView() {
        let host = SidebarHost()
        defer { host.tearDown() }

        #expect(host.rail.isHidden)
        #expect(host.rail.firstKeyViewDescendant == nil)
    }

    @Test("A shown connections strip can take the keyboard")
    func shownStripIsAKeyView() {
        let host = SidebarHost()
        defer { host.tearDown() }

        host.sidebar.setRailVisible(true, animated: false)

        #expect(!host.rail.isHidden)
        #expect(host.rail.firstKeyViewDescendant != nil)
    }

    @Test("A collapsed connections strip leaves the key view loop")
    func collapsedStripLeavesTheKeyViewLoop() {
        let host = SidebarHost()
        defer { host.tearDown() }

        host.sidebar.setRailVisible(true, animated: false)
        host.sidebar.setRailVisible(false, animated: false)

        #expect(host.rail.isHidden)
        #expect(host.rail.firstKeyViewDescendant == nil)
    }

    /// The strip collapses whenever the app-wide entry count drops to one, which closing another
    /// connection is enough to do, so the list can be holding the keyboard when it goes.
    @Test("Collapsing the connections strip lets go of the keyboard at once")
    func collapsingStripLetsGoOfTheKeyboard() throws {
        let host = SidebarHost()
        defer { host.tearDown() }

        host.sidebar.setRailVisible(true, animated: false)
        let list = try #require(host.rail.firstKeyViewDescendant)
        #expect(host.window.makeFirstResponder(list))

        host.sidebar.setRailVisible(false, animated: true)

        let responder = host.window.firstResponder as? NSView
        #expect(responder?.isDescendant(of: host.rail) != true)
    }

    /// The strip on screen at first show is the case hiding it cannot reach: two restored
    /// connections, or a connection opened while another is already open.
    @Test("A connection window leaves its first focus to the tab content, with the strip on screen")
    func firstFocusIsLeftForTheContent() throws {
        let connection = TestFixtures.makeConnection(name: "Initial focus")
        let workspace = ConnectionWorkspace(
            connectionId: connection.id,
            payload: nil,
            autoConnect: false,
            payloadConnection: connection,
            session: nil,
            sessionState: nil,
            trailingPaneState: nil,
            phase: .connecting
        )
        let window = TabWindowController.makeEditorWindow()
        window.isReleasedWhenClosed = false
        let split = MainSplitViewController(payload: nil, sessionState: nil, adopting: workspace)
        window.contentViewController = split
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            workspace.teardown()
        }

        let previous = AppSettingsManager.shared.general.showWorkspaceRail
        AppSettingsManager.shared.general.showWorkspaceRail = true
        defer { AppSettingsManager.shared.general.showWorkspaceRail = previous }
        split.applyRailVisibility(workspaceCount: 2)
        try #require(split.isWorkspaceRailVisible, "The strip has to be on screen for this to test anything")

        window.orderFront(nil)

        #expect(window.initialFirstResponder === split.initialFirstResponderContainer)
        #expect(window.firstResponder === window)
    }

    @MainActor
    private struct SidebarHost {
        let sidebar: NavigationSidebarViewController
        let window: NSWindow

        var rail: NSView {
            sidebar.railController.view
        }

        init() {
            sidebar = NavigationSidebarViewController()
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentViewController = sidebar
            window.orderFront(nil)
        }

        func tearDown() {
            window.orderOut(nil)
            window.contentViewController = nil
        }
    }
}
