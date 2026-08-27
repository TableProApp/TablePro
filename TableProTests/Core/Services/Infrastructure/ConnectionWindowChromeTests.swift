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

        harness.setRailVisible(true)
        harness.controller.transition(
            to: .unavailable(.failed(ConnectionFailureInfo(message: "refused"))),
            for: harness.selected.connectionId
        )

        #expect(harness.controller.sidebarChromeMode == .railOnly)
        #expect(harness.controller.isSidebarCollapsed)
    }

    @Test("A window with no rail still hides its sidebar outright")
    func loneConnectionStillHidesTheSidebar() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.setRailVisible(false)
        harness.controller.transition(to: .unavailable(.notConnected), for: harness.selected.connectionId)

        #expect(harness.controller.sidebarChromeMode == .hidden)
        #expect(harness.controller.isSidebarCollapsed)
    }

    @Test("The rail arriving while the connection is down opens the sidebar for it")
    func railArrivingWhileHiddenReopensTheSidebar() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.setRailVisible(false)
        harness.controller.transition(to: .unavailable(.notConnected), for: harness.selected.connectionId)
        #expect(harness.controller.sidebarChromeMode == .hidden)

        harness.setRailVisible(true)
        #expect(harness.controller.sidebarChromeMode == .railOnly)

        harness.setRailVisible(false)
        #expect(harness.controller.sidebarChromeMode == .hidden)
    }

    /// The toolbar's segment reads the same answer, so a sidebar narrowed to the rail must not
    /// report itself as showing: the segment would light up and its own action would collapse the
    /// rail away.
    @Test("Switching a connection cannot collapse a sidebar narrowed to the rail")
    func settingASidebarTabIsRefusedWhileNarrowed() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.setRailVisible(true)
        harness.controller.transition(to: .connecting, for: harness.selected.connectionId)
        #expect(harness.controller.sidebarChromeMode == .railOnly)

        harness.controller.setSidebarTab(.tables)

        #expect(harness.controller.sidebarChromeMode == .railOnly)
    }

    @Test("Switching a connection off and back on restores the sidebar the user had")
    func revealRestoresTheSidebarAcrossBothHiddenModes() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.setRailVisible(true)
        harness.controller.transition(to: .connecting, for: harness.selected.connectionId)
        #expect(harness.controller.sidebarChromeMode == .railOnly)

        harness.setRailVisible(false)
        #expect(harness.controller.sidebarChromeMode == .hidden)

        harness.setRailVisible(true)
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

        harness.setRailVisible(true)
        harness.controller.transition(to: .connecting, for: harness.selected.connectionId)

        #expect(harness.controller.sidebarChromeMode == .railOnly)
        #expect(!harness.controller.isSidebarUserCollapsible)
    }

    @Test("The rail growing under a narrowed sidebar moves both thicknesses with it")
    func narrowedSidebarTracksTheRailAllowance() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        harness.setRailVisible(true)
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

        /// The rail's own visibility is an app-wide question the harness's unregistered window
        /// cannot answer, so it is driven directly here rather than through the setting.
        func setRailVisible(_ visible: Bool) {
            controller.setWorkspaceRailVisible(visible)
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
