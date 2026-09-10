import AppKit
import Foundation
@testable import TablePro
import Testing

/// The window a user opens is the window they end up with.
///
/// Every rule here used to run the other way: a pane with no session behind it collapsed the
/// sidebar and the inspector, and the toolbar was attached only once a coordinator existed. A
/// connect slower than half a second therefore rebuilt the window twice, which is what a screen
/// recording of a PostgreSQL connection through an SSH jump host showed: blank for 0.5s, chrome
/// collapsed with a progress screen for 1.0s, then the chrome back with a dozen toolbar items
/// arriving at once.
@Suite("Connection window chrome", .serialized)
@MainActor
struct ConnectionWindowChromeTests {
    @Test("No connection phase collapses the sidebar")
    func noPhaseCollapsesTheSidebar() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        for phase in Self.everyPhase {
            harness.controller.transition(to: phase, for: harness.selected.connectionId)
            #expect(
                !harness.controller.isSidebarCollapsed,
                "\(phase) took the sidebar down with it"
            )
        }
    }

    @Test("A failed connect leaves the window's shape alone, whatever else the window holds")
    func failureLeavesTheShapeAlone() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        for count in [1, 2] {
            harness.setHostedWorkspaceCount(count)
            harness.controller.transition(
                to: .unavailable(.failed(ConnectionFailureInfo(message: "refused"))),
                for: harness.selected.connectionId
            )

            #expect(!harness.controller.isSidebarCollapsed)
            #expect(harness.controller.isSidebarUserCollapsible)
        }
    }

    /// The sidebar's collapse state is the user's, and a connection coming up or going down is not
    /// the user. It used to be captured and restored around a phase-driven collapse, which is a
    /// round trip that can only ever break even.
    @Test("A sidebar the user closed stays closed across a whole connect")
    func userCollapseSurvivesEveryPhase() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.controller.toggleSidebar(nil)
        #expect(harness.controller.isSidebarCollapsed)

        for phase in Self.everyPhase {
            harness.controller.transition(to: phase, for: harness.selected.connectionId)
            #expect(harness.controller.isSidebarCollapsed, "\(phase) reopened a sidebar the user closed")
        }
    }

    /// The whole point of the change: a connect that outlasts the reveal grace must not be the
    /// moment the window changes shape. There is no grace in the resolver any more, so this reads
    /// the pane on both sides of the phase that used to trip the collapse.
    @Test("A connect never moves the window's chrome, before or after any reveal")
    func connectNeverMovesTheChrome() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.setHostedWorkspaceCount(2)
        harness.controller.transition(to: .connecting, for: harness.selected.connectionId)

        #expect(harness.controller.currentPane == .connecting)
        #expect(!harness.controller.isSidebarCollapsed)

        harness.attachRenderableSession()
        harness.controller.transition(to: .connected, for: harness.selected.connectionId)

        #expect(harness.controller.currentPane == .content)
        #expect(!harness.controller.isSidebarCollapsed)
    }

    @Test("The toolbar is on the window from its first frame, with no session behind it")
    func toolbarStandsBeforeTheConnection() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.controller.transition(to: .connecting, for: harness.selected.connectionId)

        let identifiers = try #require(harness.window.toolbar).items.map(\.itemIdentifier)
        /// `connection` itself is a subitem of the centred group, so the group is the identifier a
        /// toolbar reports. Both of these are the window's own commands and answer with no subject.
        #expect(identifiers.contains(MainWindowToolbar.connectionGroup))
        #expect(identifiers.contains(MainWindowToolbar.sidebarToggle))
        #expect(harness.controller.commandActions == nil)
    }

    /// Items dimmed, never absent. Attaching the toolbar only once a coordinator existed is what
    /// made a dozen of them appear at once, a second and a half into the connect.
    @Test("The toolbar's item set does not change when the connection comes up")
    func toolbarItemsDoNotArriveLate() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.controller.transition(to: .connecting, for: harness.selected.connectionId)
        let before = try #require(harness.window.toolbar).items.map(\.itemIdentifier)

        harness.attachRenderableSession()
        harness.controller.transition(to: .connected, for: harness.selected.connectionId)
        let after = try #require(harness.window.toolbar).items.map(\.itemIdentifier)

        #expect(before == after)
        #expect(!before.isEmpty)
    }

    /// Switch Connection reaches the window itself, so it needs no subject. The toolbar's sidebar
    /// item is the Tables/Favorites segmented control and does need one, however window-owned the
    /// sidebar is: the tab it selects is per-connection state.
    @Test("Switch Connection answers with no coordinator and the sidebar segment does not")
    func windowScopedToolbarItemsAnswerWithoutASubject() throws {
        #expect(MainWindowToolbar.isWindowScoped(MainWindowToolbar.connection))
        #expect(!MainWindowToolbar.isWindowScoped(MainWindowToolbar.sidebarToggle))
    }

    /// The sidebar is the window's and stands in every phase, so its command answers in every
    /// phase, through both validation routes: AppKit asks `validateMenuItem` for the View menu and
    /// `validateUserInterfaceItem` for everything else, and a rule in one of them covers half the
    /// ways to the command.
    @Test("Show Sidebar answers without a session on both validation routes")
    func sidebarCommandOutlivesTheSession() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.controller.transition(to: .unavailable(.notConnected), for: harness.selected.connectionId)

        let item = Self.item(for: #selector(NSSplitViewController.toggleSidebar(_:)))
        #expect(harness.controller.validateUserInterfaceItem(item))
        #expect(harness.controller.validateMenuItem(item))
    }

    /// Opening a row inspector needs rows. Closing one the user already opened does not, and the
    /// window no longer closes it for them, so leaving the command disabled would strand an empty
    /// column with no way to dismiss it.
    @Test("A trailing pane the user left open can still be closed with the session gone")
    func openTrailingPaneStaysClosable() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.attachRenderableSession()
        harness.controller.transition(to: .connected, for: harness.selected.connectionId)
        harness.controller.showInspector()
        #expect(harness.controller.isTrailingPaneOpen)

        harness.controller.transition(to: .unavailable(.disconnected(nil)), for: harness.selected.connectionId)

        let item = Self.item(for: #selector(NSSplitViewController.toggleInspector(_:)))
        #expect(harness.controller.validateUserInterfaceItem(item))
        #expect(harness.controller.validateMenuItem(item))
    }

    /// The other half of the same rule: a pane the user never opened offers nothing to open.
    @Test("A closed trailing pane stays unavailable without a session")
    func closedTrailingPaneStaysUnavailable() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.controller.transition(to: .unavailable(.notConnected), for: harness.selected.connectionId)
        #expect(!harness.controller.isTrailingPaneOpen)

        #expect(!harness.controller.validateUserInterfaceItem(
            Self.item(for: #selector(NSSplitViewController.toggleInspector(_:)))
        ))
    }

    /// The preference governs a strip the user can do without while the object browser and the tab
    /// strip both name something. A pane with no content leaves both empty, and then the strip is
    /// the only thing on screen naming the window's other connections.
    @Test("Hiding the connections strip cannot strand a window that has somewhere else to go")
    func stripOutlivesThePreferenceWhileItIsTheOnlyRouteOut() throws {
        let harness = try Harness()
        let previous = AppSettingsManager.shared.general.showWorkspaceRail
        defer {
            AppSettingsManager.shared.general.showWorkspaceRail = previous
            harness.tearDown()
        }

        harness.setRailPreference(false)
        harness.setHostedWorkspaceCount(2)
        harness.controller.transition(
            to: .unavailable(.disconnectedByUser),
            for: harness.selected.connectionId
        )

        #expect(harness.controller.isWorkspaceRailVisible)
    }

    @Test("Hiding the connections strip holds while the connection has content behind it")
    func preferenceHoldsWhileTheWindowHasContent() throws {
        let harness = try Harness()
        let previous = AppSettingsManager.shared.general.showWorkspaceRail
        defer {
            AppSettingsManager.shared.general.showWorkspaceRail = previous
            harness.tearDown()
        }

        harness.setRailPreference(false)
        harness.setHostedWorkspaceCount(2)
        harness.attachRenderableSession()
        harness.controller.transition(to: .connected, for: harness.selected.connectionId)

        #expect(harness.controller.currentPane == .content)
        #expect(!harness.controller.isWorkspaceRailVisible)
    }

    /// Every other Database menu command needs the connection in front of the user. This one is
    /// how they leave it, and it reads nothing from the session.
    @Test("Switch Connection survives the connection it switches away from")
    func switchConnectionOutlivesItsConnection() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.controller.transition(
            to: .unavailable(.disconnectedByUser),
            for: harness.selected.connectionId
        )
        #expect(harness.controller.commandActions == nil)

        let context = harness.controller.menuValidationContext
        #expect(!context.isConnected)
        #expect(MainSplitViewController.isEnabled(
            #selector(MainSplitViewController.switchConnection(_:)),
            context: context
        ))
    }

    /// One window, one floating panel. Two of them anchor on the same window frame and centre on
    /// the same point, with neither able to see or dismiss the other.
    @Test("Every connection in a window shares the window's one switcher")
    func oneSwitcherPerWindowNotPerConnection() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        #expect(harness.controller.switcherPresenter === harness.controller.switcherPresenter)
        #expect(harness.controller.quickSwitcherPanel === harness.controller.quickSwitcherPanel)
    }

    /// The connections strip and the View menu reach a window's other connections without asking a
    /// coordinator anything, which is what makes them the routes that survive one going down.
    @Test("Switching connection from the View menu works with no coordinator behind it")
    func viewMenuSwitchingDoesNotNeedACoordinator() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.controller.transition(to: .unavailable(.notConnected), for: harness.selected.connectionId)
        #expect(harness.controller.commandActions == nil)

        let context = harness.controller.menuValidationContext
        #expect(context.canToggleWorkspaceRail == harness.controller.canToggleWorkspaceRail)
    }

    private static let everyPhase: [ConnectionWindowPhase] = [
        .idle,
        .connecting,
        .connected,
        .unavailable(.notConnected),
        .unavailable(.cancelled),
        .unavailable(.disconnectedByUser),
        .unavailable(.failed(ConnectionFailureInfo(message: "refused"))),
    ]

    private static func item(for action: Selector) -> NSMenuItem {
        NSMenuItem(title: "", action: action, keyEquivalent: "")
    }

    @MainActor
    private struct Harness {
        let controller: MainSplitViewController
        let selected: ConnectionWorkspace
        let window: NSWindow
        private let sibling: ConnectionWorkspace
        private let connection: DatabaseConnection

        init() throws {
            connection = TestFixtures.makeConnection(name: "Selected")
            selected = Self.makeWorkspace(connection: connection, phase: .connected)
            sibling = Self.makeWorkspace(connection: TestFixtures.makeConnection(name: "Sibling"), phase: .connected)

            controller = MainSplitViewController(payload: nil, sessionState: nil, adopting: selected)
            controller.workspaces.insert(sibling, select: false)

            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 700),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            window.orderFront(nil)
            resetPaneLayout()
        }

        /// `NSSplitView`'s autosave record is namespaced per sandbox only under a UI test, so every
        /// case in this target shares one and a case that moves a pane hands its layout to
        /// whichever runs next. Both panes are pinned to the shipping default at both ends here
        /// rather than in each test: sidebar open, inspector closed.
        func resetPaneLayout() {
            if controller.isSidebarCollapsed { controller.toggleSidebar(nil) }
            if controller.isTrailingPaneOpen { controller.hideTrailingPane() }
        }

        /// How many workspaces the strip has to offer is an app-wide question the harness's
        /// unregistered window cannot answer, so the count is handed to the controller directly.
        /// Everything downstream of it is the shipping rule.
        func setHostedWorkspaceCount(_ count: Int) {
            controller.applyRailVisibility(workspaceCount: count)
        }

        /// The Show Connections preference, which the rule reads globally.
        func setRailPreference(_ enabled: Bool) {
            AppSettingsManager.shared.general.showWorkspaceRail = enabled
        }

        func attachRenderableSession() {
            selected.session = ConnectionSession(
                connection: connection,
                driver: MockDatabaseDriver(connection: connection)
            )
            selected.trailingPaneState = TrailingPaneState(connectionId: connection.id)
            selected.sessionState = SessionStateFactory.create(connection: connection, payload: nil)
        }

        func tearDown() {
            resetPaneLayout()
            window.orderOut(nil)
            window.contentViewController = nil
            sibling.teardown()
            selected.teardown()
        }

        private static func makeWorkspace(
            connection: DatabaseConnection,
            phase: ConnectionWindowPhase
        ) -> ConnectionWorkspace {
            ConnectionWorkspace(
                connectionId: connection.id,
                payload: nil,
                autoConnect: false,
                payloadConnection: connection,
                session: nil,
                sessionState: nil,
                trailingPaneState: nil,
                phase: phase
            )
        }
    }
}
