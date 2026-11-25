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
@MainActor
struct ConnectionWindowInitialFocusTests {
    @Test("A connections strip that has never been shown is not a key view")
    func unshownStripIsNotAKeyView() {
        let host = SidebarHost()
        defer { host.tearDown() }

        #expect(host.rail.isHiddenOrHasHiddenAncestor)
        #expect(host.rail.firstKeyViewDescendant == nil)
    }

    @Test("A shown connections strip can take the keyboard")
    func shownStripIsAKeyView() {
        let host = SidebarHost()
        defer { host.tearDown() }

        host.sidebar.setRailVisible(true, animated: false)

        #expect(!host.rail.isHiddenOrHasHiddenAncestor)
        #expect(host.rail.firstKeyViewDescendant != nil)
    }

    @Test("A collapsed connections strip leaves the key view loop")
    func collapsedStripLeavesTheKeyViewLoop() {
        let host = SidebarHost()
        defer { host.tearDown() }

        host.sidebar.setRailVisible(true, animated: false)
        host.sidebar.setRailVisible(false, animated: false)

        #expect(host.rail.isHiddenOrHasHiddenAncestor)
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

    /// Leaving the keyboard with the window itself would make every key beep until the next click,
    /// so it goes where AppKit sends it when a focused view is hidden: the next key view.
    @Test("Collapsing the connections strip hands the keyboard to the next key view")
    func collapsingStripHandsTheKeyboardOn() throws {
        let host = SidebarHost()
        defer { host.tearDown() }
        let field = NSTextField(frame: NSRect(x: 400, y: 200, width: 120, height: 22))
        host.sidebar.view.addSubview(field)

        host.sidebar.setRailVisible(true, animated: false)
        let list = try #require(host.rail.firstKeyViewDescendant)
        #expect(host.window.makeFirstResponder(list))

        host.sidebar.setRailVisible(false, animated: true)

        #expect(host.window.firstResponder !== host.window)
        let responder = host.window.firstResponder as? NSView
        #expect(responder?.isDescendant(of: host.rail) == false)
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

    // A connection already up when its window opens has the sidebar filter enabled from the first frame, and AppKit's
    // first-show pick walked on from the container, which refuses focus, to that field.
    @Test("A key view in the sidebar at first show leaves the window's first focus to the content")
    func firstFocusSkipsAnEnabledSidebarKeyView() throws {
        let host = try ConnectionWindowHost()
        defer { host.tearDown() }
        host.sidebar.addSubview(NSTextField(frame: NSRect(x: 10, y: host.sidebar.bounds.maxY - 80, width: 160, height: 22)))

        host.window.orderFront(nil)

        #expect(host.window.firstResponder === host.window)
        host.window.selectNextKeyView(nil)
        #expect(host.window.firstResponder !== host.window, "Tab from the empty window still reaches a key view")
    }

    // The two halves of the fix only work together: without the container, the field takes the pick before the
    // list's turn comes.
    @Test("An object list built before first show takes the first focus over an enabled sidebar field")
    func objectListTakesFirstFocus() async throws {
        let host = try ConnectionWindowHost()
        defer { host.tearDown() }
        let sidebar = host.sidebar
        sidebar.addSubview(NSTextField(frame: NSRect(x: 10, y: sidebar.bounds.maxY - 80, width: 160, height: 22)))
        let list = SidebarOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("column"))
        list.addTableColumn(column)
        list.outlineTableColumn = column
        sidebar.addSubview(list)

        host.window.orderFront(nil)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        #expect(host.window.firstResponder === list)
    }

    @MainActor
    private struct ConnectionWindowHost {
        let window: NSWindow
        let sidebar: NSView
        private let workspace: ConnectionWorkspace

        init() throws {
            let connection = TestFixtures.makeConnection(name: "Initial focus, connected")
            workspace = ConnectionWorkspace(
                connectionId: connection.id,
                payload: nil,
                autoConnect: false,
                payloadConnection: connection,
                session: nil,
                sessionState: nil,
                trailingPaneState: nil,
                phase: .connecting
            )
            window = TabWindowController.makeEditorWindow()
            window.isReleasedWhenClosed = false
            let split = MainSplitViewController(payload: nil, sessionState: nil, adopting: workspace)
            window.contentViewController = split
            sidebar = try #require(split.splitViewItems.first?.viewController.view)
        }

        func tearDown() {
            window.orderOut(nil)
            window.contentViewController = nil
            workspace.teardown()
        }
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
            window.keepsKeyViewLoopCurrent()
            window.contentViewController = sidebar
            window.orderFront(nil)
        }

        func tearDown() {
            window.orderOut(nil)
            window.contentViewController = nil
        }
    }
}
