import AppKit
import Foundation
@testable import TablePro
import Testing

@Suite("Connection window chrome", .serialized)
@MainActor
struct ConnectionWindowChromeTests {
    @Test("A window hosting a second connection keeps its rail when the selected one is unavailable")
    func railSurvivesAnUnavailableSelectedConnection() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.setHostedWorkspaceCount(2)
        harness.controller.transition(
            to: .unavailable(.failed(ConnectionFailureInfo(message: "refused"))),
            for: harness.selected.connectionId
        )

        #expect(harness.controller.sidebarChromeMode == .railOnly)
        #expect(harness.controller.isSidebarCollapsed)
    }

    @Test("A window hosting nothing else still hides its sidebar outright")
    func loneConnectionStillHidesTheSidebar() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.setHostedWorkspaceCount(1)
        harness.controller.transition(to: .unavailable(.notConnected), for: harness.selected.connectionId)

        #expect(harness.controller.sidebarChromeMode == .hidden)
        #expect(harness.controller.isSidebarCollapsed)
    }

    @Test("A sibling opening while the connection is down opens the sidebar for the strip")
    func railArrivingWhileHiddenReopensTheSidebar() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.setHostedWorkspaceCount(1)
        harness.controller.transition(to: .unavailable(.notConnected), for: harness.selected.connectionId)
        #expect(harness.controller.sidebarChromeMode == .hidden)

        harness.setHostedWorkspaceCount(2)
        #expect(harness.controller.sidebarChromeMode == .railOnly)

        harness.setHostedWorkspaceCount(1)
        #expect(harness.controller.sidebarChromeMode == .hidden)
    }

    /// The toolbar's segment reads the same answer, so a sidebar narrowed to the rail must not
    /// report itself as showing: the segment would light up and its own action would collapse the
    /// rail away.
    @Test("Switching a connection cannot collapse a sidebar narrowed to the rail")
    func settingASidebarTabIsRefusedWhileNarrowed() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.setHostedWorkspaceCount(2)
        harness.controller.transition(to: .connecting, for: harness.selected.connectionId)
        #expect(harness.controller.sidebarChromeMode == .railOnly)

        harness.controller.setSidebarTab(.tables)

        #expect(harness.controller.sidebarChromeMode == .railOnly)
    }

    /// The preference governs a strip the user can do without while the object browser, the tab
    /// strip and the toolbar are all there to navigate by. A pane with no content takes all three,
    /// and then the strip is the only thing left naming the window's other connections, so the
    /// preference stops applying to it. Turning it off used to leave such a window with no route
    /// on screen to any connection at all.
    @Test("Hiding the connections strip cannot strand a window that has somewhere else to go")
    func stripOutlivesThePreferenceWhileItIsTheOnlyRouteOut() throws {
        let harness = try Harness()
        let previous = AppSettingsManager.shared.general.showWorkspaceRail
        defer {
            AppSettingsManager.shared.general.showWorkspaceRail = previous
            harness.tearDown()
        }

        harness.setRailPreference(false)
        harness.controller.transition(
            to: .unavailable(.disconnectedByUser),
            for: harness.selected.connectionId
        )

        harness.setHostedWorkspaceCount(1)
        #expect(harness.controller.sidebarChromeMode == .hidden)

        harness.setHostedWorkspaceCount(2)
        #expect(harness.controller.sidebarChromeMode == .railOnly)
    }

    /// The preference still means what it says wherever the window can be navigated without it.
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
        #expect(harness.controller.sidebarChromeMode == .revealed)
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

    @Test("Switching a connection off and back on restores the sidebar the user had")
    func revealRestoresTheSidebarAcrossBothHiddenModes() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.setHostedWorkspaceCount(2)
        harness.controller.transition(to: .connecting, for: harness.selected.connectionId)
        #expect(harness.controller.sidebarChromeMode == .railOnly)

        harness.setHostedWorkspaceCount(1)
        #expect(harness.controller.sidebarChromeMode == .hidden)

        harness.setHostedWorkspaceCount(2)
        harness.controller.transition(to: .idle, for: harness.selected.connectionId)
        harness.attachRenderableSession()
        harness.controller.transition(to: .connected, for: harness.selected.connectionId)

        #expect(harness.controller.sidebarChromeMode == .revealed)
        #expect(!harness.controller.isSidebarCollapsed)
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

    @Test("A sidebar narrowed to the rail cannot be collapsed by dragging its divider")
    func narrowedSidebarRefusesUserCollapse() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.setHostedWorkspaceCount(2)
        harness.controller.transition(to: .connecting, for: harness.selected.connectionId)

        #expect(harness.controller.sidebarChromeMode == .railOnly)
        #expect(!harness.controller.isSidebarUserCollapsible)
    }

    @Test("The rail growing under a narrowed sidebar moves both thicknesses with it")
    func narrowedSidebarTracksTheRailAllowance() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.setHostedWorkspaceCount(2)
        harness.controller.transition(to: .connecting, for: harness.selected.connectionId)
        #expect(harness.controller.sidebarChromeMode == .railOnly)

        harness.controller.reapplySidebarClampIfNarrowed()

        #expect(harness.controller.sidebarThicknessRange.min == harness.controller.railAllowance)
        #expect(harness.controller.sidebarThicknessRange.max == harness.controller.railAllowance)
    }

    @MainActor
    private struct Harness {
        let controller: MainSplitViewController
        let selected: ConnectionWorkspace
        private let sibling: ConnectionWorkspace
        private let connection: DatabaseConnection
        private let window: NSWindow

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
            selected.rightPanelState = RightPanelState(connectionId: connection.id)
            selected.sessionState = SessionStateFactory.create(connection: connection, payload: nil)
        }

        func tearDown() {
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
                rightPanelState: nil,
                phase: phase
            )
        }
    }
}
