//
//  AgentModeWindowTests.swift
//  TableProTests
//
//  Entering or leaving Agent mode used to rebuild the connection's browse tree. The conversation and
//  the browse content were two arms of one `@ViewBuilder` conditional in the detail pane, and the
//  session rail and the object browser two arms in the sidebar, so every toggle was an identity
//  change that threw away grid scroll, cell selection, the editor's find panel and undo stack and an
//  unsaved Create Table definition. The mode now reparents panes of its own, and the window stops
//  describing a tree it is not drawing: the tab strip, the title, the detail column's minimum and
//  the Safe Mode list all follow the swap.
//

import AppKit
import Foundation
@testable import TablePro
import Testing

@Suite("Agent mode window", .serialized)
@MainActor
struct AgentModeWindowTests {
    // MARK: - The browse tree survives

    /// `WindowAccessorView` is the AppKit view behind `MainContentView`'s window accessor, so it
    /// lives exactly as long as the browse tree's identity does. A rebuild makes a new one.
    @Test("Toggling Agent mode on and off keeps the browse pane and the tree in it")
    func toggleKeepsTheBrowseTree() throws {
        try AIFeatureScope.enabled {
            let harness = try Harness()
            defer { harness.tearDown() }
            try harness.requireContent()
            let detail = harness.selected.panes.detail
            let accessor = try #require(
                harness.settle { detail.view.firstDescendant(of: WindowAccessorView.self) },
                "The browse content never mounted, so the case proves nothing"
            )

            harness.controller.setContentMode(.agent)

            #expect(harness.controller.detailPaneHost.shown === harness.selected.panes.agentConversation)
            #expect(harness.controller.shownSidebarPane === harness.selected.panes.agentRail)
            #expect(detail.view.superview == nil, "The browse pane is unparented, not rebuilt in place")
            harness.drain()

            harness.controller.setContentMode(.browse)

            #expect(harness.controller.detailPaneHost.shown === detail)
            #expect(harness.controller.shownSidebarPane === harness.selected.panes.sidebar)
            let remounted = harness.settle { detail.view.firstDescendant(of: WindowAccessorView.self) }
            #expect(remounted === accessor, "The browse tree was rebuilt, and everything only it held went with it")
        }
    }

    // MARK: - Agent mode's panes are built once

    /// The rail's list is an AppKit outline view behind SwiftUI's `List`, so it too lives exactly as
    /// long as the rail's identity does.
    @Test("Agent mode's panes are built once and kept across toggles")
    func agentPanesAreReused() throws {
        try AIFeatureScope.enabled {
            let harness = try Harness()
            defer { harness.tearDown() }
            try harness.requireContent()
            let rail = harness.selected.panes.agentRail
            let conversation = harness.selected.panes.agentConversation

            harness.controller.setContentMode(.agent)
            #expect(harness.controller.shownSidebarPane === rail)
            #expect(harness.controller.detailPaneHost.shown === conversation)
            let list = try #require(
                harness.settle { rail.view.firstDescendant(of: NSTableView.self) },
                "The session rail never listed its session"
            )

            harness.controller.setContentMode(.browse)
            #expect(rail.view.superview == nil)
            #expect(conversation.view.superview == nil)
            harness.drain()

            harness.controller.setContentMode(.agent)
            #expect(harness.controller.shownSidebarPane === rail)
            #expect(harness.controller.detailPaneHost.shown === conversation)
            #expect(harness.settle { rail.view.firstDescendant(of: NSTableView.self) } === list)
        }
    }

    /// A session already exists, so a rail built while browsing would list it. The pane is mounted
    /// in a window of its own to look, because an unmounted pane shows nothing whatever it holds.
    @Test("Browsing builds nothing of Agent mode")
    func browsingBuildsNoAgentContent() throws {
        try AIFeatureScope.enabled {
            let harness = try Harness(startsAgentSession: true)
            defer { harness.tearDown() }
            try harness.requireContent()
            let rail = harness.selected.panes.agentRail

            let probe = PaneProbeWindow(showing: rail.view)
            probe.settle()
            #expect(rail.view.firstDescendant(of: NSTableView.self) == nil, "The rail was built for a mode nobody entered")
            probe.close()

            harness.controller.setContentMode(.agent)
            #expect(harness.settle { rail.view.firstDescendant(of: NSTableView.self) } != nil)
        }
    }

    // MARK: - A background connection

    /// The #2545 shape: panes are built for the new state at once, whether the connection is on
    /// screen or not, and parented only when it is selected.
    @Test("A connection put into Agent mode in the background shows its conversation once selected")
    func backgroundAgentModeIsParentedOnSelection() throws {
        try AIFeatureScope.enabled {
            let harness = TwoConnectionHarness()
            defer { harness.tearDown() }
            harness.controller.transition(to: .connecting, for: harness.background.connectionId)
            try #require(harness.background.resolvedPane == .connecting)

            harness.controller.setContentMode(.agent, for: harness.background.connectionId)

            #expect(harness.background.panes.renderedKey?.contentMode == .agent)
            #expect(harness.controller.detailPaneHost.shown === harness.foreground.panes.detail)
            #expect(harness.background.panes.agentConversation.parent == nil)

            harness.controller.workspaces.select(harness.background.connectionId)

            #expect(harness.controller.detailPaneHost.shown === harness.background.panes.agentConversation)
            #expect(harness.controller.shownSidebarPane === harness.background.panes.agentRail)
            #expect(harness.controller.inspectorPaneHost.shown === harness.background.panes.agentResult)
        }
    }

    // MARK: - The window describes what it draws

    @Test("Agent mode takes the tab strip down and names the window after the session")
    func agentModeDropsTheTabStripAndRenamesTheWindow() throws {
        try AIFeatureScope.enabled {
            let harness = try Harness()
            defer { harness.tearDown() }
            try harness.requireContent()
            let tabManager = try #require(harness.selected.sessionState?.tabManager)
            tabManager.addTab(initialQuery: "SELECT 1")
            tabManager.addTab(initialQuery: "SELECT 2")
            harness.controller.applyTabStripVisibility()
            harness.controller.applyWindowTitle()
            try #require(!harness.controller.tabStripAccessory.isHidden, "Two tabs over browse content show the strip")
            let browseTitle = harness.controller.windowTitle

            harness.controller.setContentMode(.agent)

            #expect(harness.controller.tabStripAccessory.isHidden)
            #expect(harness.controller.windowTitle == ConnectionWorkspaceContentMode.agent.localizedTitle)
            #expect(harness.window.title == harness.controller.windowTitle)

            harness.controller.setContentMode(.browse)

            #expect(!harness.controller.tabStripAccessory.isHidden)
            #expect(harness.controller.windowTitle == browseTitle)
        }
    }

    /// A session names itself from its first question or reply, which lands after the mode came on.
    @Test("The window follows the session as it gets a name")
    func titleFollowsTheSession() async throws {
        try await AIFeatureScope.enabled {
            let harness = try Harness()
            defer { harness.tearDown() }
            try harness.requireContent()
            harness.controller.setContentMode(.agent)
            let session = try #require(harness.selected.displayedAgentSession)
            #expect(harness.controller.windowTitle == ConnectionWorkspaceContentMode.agent.localizedTitle)

            session.viewModel.messages.append(ChatTurn(role: .user, blocks: [.text("Which orders shipped late?")]))

            #expect(await harness.suspend { harness.controller.windowTitle == "Which orders shipped late?" })
            #expect(harness.window.title == "Which orders shipped late?")
        }
    }

    /// The proxy icon is the rest of what the titlebar says. The browse content wrote it straight to
    /// the window, so a query file's icon and its Command-click path menu stayed beside the
    /// session's name.
    @Test("Agent mode takes a file's proxy icon down and browsing puts it back")
    func agentModeDropsTheProxyIcon() throws {
        try AIFeatureScope.enabled {
            let harness = try Harness()
            defer { harness.tearDown() }
            try harness.requireContent()
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("AgentModeWindowTests-\(UUID().uuidString).sql")
            try Data("SELECT 1".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            let tabManager = try #require(harness.selected.sessionState?.tabManager)
            tabManager.addTab(initialQuery: "SELECT 1", sourceFileURL: file)
            harness.controller.applyWindowTitle()
            try #require(
                harness.window.representedURL == file,
                "The file's tab never set the icon, so the case proves nothing"
            )

            harness.controller.setContentMode(.agent)
            #expect(harness.window.representedURL == nil)
            harness.drain()
            #expect(harness.window.representedURL == nil, "The browse tree behind the conversation put its file back")

            harness.controller.setContentMode(.browse)
            #expect(harness.window.representedURL == file)
        }
    }

    @Test("A Users & Roles tab behind the conversation does not set the detail column's floor")
    func agentModeKeepsTheDefaultDetailFloor() throws {
        try AIFeatureScope.enabled {
            let harness = try Harness()
            defer { harness.tearDown() }
            try harness.requireContent()
            let tabManager = try #require(harness.selected.sessionState?.tabManager)
            tabManager.adoptTab(QueryTab(id: UUID(), title: "Users & Roles", query: "", tabType: .usersRoles))
            harness.controller.updateDetailMinimumThickness(for: .usersRoles, connectionId: harness.connection.id)
            try #require(harness.detailItem.minimumThickness == UsersRolesLayoutMetrics.tabMinimumWidth)

            harness.controller.setContentMode(.agent)
            #expect(harness.detailItem.minimumThickness == MainSplitViewController.defaultDetailMinThickness)

            harness.controller.updateDetailMinimumThickness(for: .usersRoles, connectionId: harness.connection.id)
            #expect(
                harness.detailItem.minimumThickness == MainSplitViewController.defaultDetailMinThickness,
                "The browse tree reporting its tab from behind the conversation raised it again"
            )

            harness.controller.setContentMode(.browse)
            #expect(harness.detailItem.minimumThickness == UsersRolesLayoutMetrics.tabMinimumWidth)
        }
    }

    /// The error, Retry and Manage Connections live on the browse side's unavailable screen, and a
    /// composer with none of them is a dead end. A reconnect hands the column back.
    @Test("A connection that drops in Agent mode shows the unavailable screen, and a reconnect the conversation")
    func droppedConnectionHandsTheColumnBack() throws {
        try AIFeatureScope.enabled {
            let harness = try Harness()
            defer { harness.tearDown() }
            try harness.requireContent()
            harness.controller.setContentMode(.agent)
            #expect(harness.controller.detailPaneHost.shown === harness.selected.panes.agentConversation)

            DatabaseManager.shared.removeSession(for: harness.connection.id)
            harness.controller.refreshFromActiveSessions()

            #expect(!harness.controller.currentPane.hasContent)
            #expect(harness.controller.detailPaneHost.shown === harness.selected.panes.detail)
            #expect(harness.controller.windowTitle == harness.connection.name)

            harness.inject(status: .connected)
            harness.controller.refreshFromActiveSessions()

            #expect(harness.controller.currentPane == .content)
            #expect(harness.controller.detailPaneHost.shown === harness.selected.panes.agentConversation)
        }
    }

    /// The conversation stays built, detached, behind the unavailable screen of a connection that
    /// dropped. A search of its pane still found the composer there, so Focus Assistant stayed
    /// enabled and moved focus off Retry and onto the window.
    @Test("Focus Assistant is dimmed once the conversation has left the detail column")
    func focusAssistantFollowsTheConversationOffScreen() throws {
        try AIFeatureScope.enabled {
            let harness = try Harness()
            defer { harness.tearDown() }
            try harness.requireContent()
            harness.controller.setContentMode(.agent)
            /// Stands in for the composer the conversation draws once a session has a provider to
            /// answer it, which a unit test has no way to configure.
            let composer = ChatComposerNSTextView.make()
            harness.selected.panes.agentConversation.view.addSubview(composer)
            let item = Self.menuItem(#selector(MainSplitViewController.focusAssistant(_:)))
            try #require(
                harness.controller.validateMenuItem(item),
                "The composer on screen was not reachable, so the case proves nothing"
            )

            DatabaseManager.shared.removeSession(for: harness.connection.id)
            harness.controller.refreshFromActiveSessions()
            try #require(harness.controller.detailPaneHost.shown === harness.selected.panes.detail)
            try #require(composer.superview != nil, "The conversation was torn down rather than kept")

            #expect(!harness.controller.validateMenuItem(item))
            #expect(!harness.controller.focusAssistantPane())
            #expect(harness.window.firstResponder !== composer)
        }
    }

    // MARK: - One registry

    /// The assistant in the trailing pane and Agent mode have to draw one set of sessions. The pane
    /// state the window builds as a session lands took the app's registry whatever registry the
    /// workspace had been handed, so the two could name different sessions for one connection.
    @Test("The trailing pane state the window builds shares the workspace's registry")
    func builtPaneStateSharesTheWorkspaceRegistry() throws {
        try AIFeatureScope.enabled {
            let harness = try Harness(prebuildsPaneState: false)
            defer { harness.tearDown() }
            try harness.requireContent()
            let paneState = try #require(harness.selected.trailingPaneState, "The window built no pane state")

            let session = harness.agentSessions.startSession(for: harness.connection.id)

            #expect(paneState.assistant.session === session)
        }
    }

    /// Every toggle re-runs the conversation's tasks on the same view. A prompt held for the connect
    /// is neither sent early nor dropped, and nothing starts a second session or conversation.
    ///
    /// The flush marks the engine as waiting for the connection each time it runs, which is how the
    /// case knows the toggle really re-ran it rather than passing because nothing ran at all.
    @Test("A toggle during the connect neither sends the held prompt nor starts a second session")
    func toggleDuringTheConnectKeepsTheHeldPrompt() async throws {
        try await AIFeatureScope.enabled {
            let harness = try Harness(sessionStatus: .connecting)
            defer { harness.tearDown() }
            try #require(harness.controller.currentPane == .connecting)
            let session = harness.agentSessions.startSession(for: harness.connection.id)
            session.pendingPrompt = "Which orders shipped late?"

            harness.controller.setContentMode(.agent)
            #expect(harness.controller.detailPaneHost.shown === harness.selected.panes.agentConversation)
            try #require(
                await harness.suspend { session.viewModel.isAwaitingConnection },
                "The conversation never ran its flush"
            )

            harness.controller.setContentMode(.browse)
            await harness.pause()
            session.viewModel.isAwaitingConnection = false
            harness.controller.setContentMode(.agent)
            try #require(
                await harness.suspend { session.viewModel.isAwaitingConnection },
                "Coming back did not run the flush again, so the case proves nothing"
            )

            #expect(session.pendingPrompt == "Which orders shipped late?")
            #expect(session.viewModel.messages.isEmpty)
            #expect(session.viewModel.activeConversationID == nil)
            #expect(harness.agentSessions.sessions(for: harness.connection.id).map(\.id) == [session.id])
        }
    }

    // MARK: - Safe Mode

    /// The list, its validation and the write all judge a level by one status. The validation used
    /// to ask the connection's own floor while the write asked the one Agent mode raises, so an entry
    /// could validate as a choice the write then held at another level.
    @Test("Each Safe Mode entry validates against the floor the list is built from")
    func safeModeEntriesFollowTheListsFloor() throws {
        let harness = try Harness(type: .cloudflareR2SQL)
        defer { harness.tearDown() }
        try harness.requireContent()
        let status = try #require(harness.controller.safeModeStatus)
        try #require(status.floor?.reason == .readOnlyEngine)

        for level in SafeModeLevel.allCases {
            #expect(
                harness.controller.validateMenuItem(Self.safeModeItem(level)) == status.offers(level),
                "\(level)"
            )
        }
        #expect(!harness.controller.validateMenuItem(Self.safeModeItem(.silent)))
    }

    /// The welcome window's Open in Agent Mode puts the window in the mode before its connect lands,
    /// so the browse content, which is what used to hand the list its coordinator, never mounts.
    /// The list had no checkmark and no entry in it did anything.
    @Test("The Safe Mode list works in a window opened straight into Agent mode")
    func safeModeWorksWithoutTheBrowseContent() throws {
        try AIFeatureScope.enabled {
            let harness = try Harness(contentMode: .agent)
            defer { harness.tearDown() }
            try harness.requireContent()
            try #require(
                harness.controller.commandActions == nil,
                "The browse content mounted, so this is not the window the welcome route opens"
            )
            let status = try #require(harness.controller.safeModeStatus, "The list had no level to check")
            let pick = try #require(status.offeredLevels.first { status.accepts($0) })
            let item = Self.safeModeItem(pick)
            #expect(harness.controller.validateMenuItem(item))

            harness.controller.setSafeModeLevel(item)

            #expect(DatabaseManager.shared.session(for: harness.connection.id)?.safeModeLevel == pick)
            #expect(harness.controller.safeModeStatus?.level == pick)
        }
    }

    private static func safeModeItem(_ level: SafeModeLevel) -> NSMenuItem {
        let item = menuItem(#selector(MainSplitViewController.setSafeModeLevel(_:)))
        item.title = level.displayName
        item.representedObject = level.rawValue
        return item
    }

    private static func menuItem(_ action: Selector) -> NSMenuItem {
        NSMenuItem(title: "", action: action, keyEquivalent: "")
    }

    // MARK: - Harnesses

    /// One connection whose session the window adopts from `DatabaseManager`, the way a real connect
    /// lands. Its agent sessions live in a registry of its own, in a directory of its own, so
    /// entering Agent mode writes nothing into the user's real session store.
    @MainActor
    private struct Harness {
        let controller: MainSplitViewController
        let selected: ConnectionWorkspace
        let agentSessions: AgentSessionRegistry
        let window: NSWindow
        let connection: DatabaseConnection
        private let defaults: UserDefaults
        private let suiteName: String
        private let registryDirectory: URL

        var detailItem: NSSplitViewItem {
            controller.splitViewItems[1]
        }

        /// `contentMode` is set before the window is built, which is how the welcome window's Open in
        /// Agent Mode lands: the mode is on before the connect, so the browse content never mounts.
        ///
        /// `prebuildsPaneState` false leaves the trailing pane state for the window to build as the
        /// session lands, which is how every workspace the app opens gets one.
        init(
            type: DatabaseType = .mysql,
            sessionStatus: ConnectionStatus = .connected,
            contentMode: ConnectionWorkspaceContentMode = .browse,
            startsAgentSession: Bool = false,
            prebuildsPaneState: Bool = true
        ) throws {
            connection = TestFixtures.makeConnection(name: "Agent window", type: type)
            suiteName = "AgentModeWindowTests.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suiteName))
            registryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("AgentModeWindowTests-\(UUID().uuidString)", isDirectory: true)
            agentSessions = AgentSessionRegistry(store: AgentSessionStore(directory: registryDirectory))
            if startsAgentSession {
                agentSessions.startSession(for: connection.id)
            }
            let paneState = prebuildsPaneState
                ? TrailingPaneState(connectionId: connection.id, defaults: defaults, sessionRegistry: agentSessions)
                : nil
            selected = ConnectionWorkspace(
                connectionId: connection.id,
                payload: nil,
                autoConnect: false,
                payloadConnection: connection,
                session: nil,
                sessionState: nil,
                trailingPaneState: paneState,
                phase: .connecting,
                agentSessions: agentSessions
            )
            selected.contentMode = contentMode
            controller = MainSplitViewController(payload: nil, sessionState: nil, adopting: selected)
            /// Before the window appears, so the status pass it runs as it does finds the session.
            /// A connect still in flight is otherwise read as a connect nobody owns, and failed.
            Self.inject(status: sessionStatus, for: connection)

            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 700),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            window.orderFront(nil)

            controller.refreshFromActiveSessions()
            resetPaneLayout()
        }

        func inject(status: ConnectionStatus) {
            Self.inject(status: status, for: connection)
        }

        private static func inject(status: ConnectionStatus, for connection: DatabaseConnection) {
            var session = ConnectionSession(
                connection: connection,
                driver: status == .connected ? MockDatabaseDriver(connection: connection) : nil
            )
            session.status = status
            DatabaseManager.shared.injectSession(session, for: connection.id)
        }

        /// Asked after the caller has registered `tearDown`, so a harness that failed to connect
        /// still gives its window and its injected session back.
        func requireContent() throws {
            try #require(controller.currentPane == .content, "The connection has no content behind it")
        }

        /// SwiftUI mounts a pane on the next layout pass, so anything read out of one waits for it.
        func settle<Found: AnyObject>(_ find: () -> Found?) -> Found? {
            let deadline = Date(timeIntervalSinceNow: 5)
            while Date() < deadline {
                window.contentView?.layoutSubtreeIfNeeded()
                if let found = find() { return found }
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            }
            return find()
        }

        /// A session derives its name on a main-actor task of its own, and a synchronous spin of the
        /// run loop from inside this test's own main-actor job never lets that task run: measured,
        /// a `Task { @MainActor in }` did not run across a hundred 10ms turns. So this suspends
        /// instead, in a bounded count of short steps, and a missing change fails rather than hangs.
        func suspend(until condition: () -> Bool) async -> Bool {
            for _ in 0 ..< 200 {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return condition()
        }

        func pause() async {
            for _ in 0 ..< 10 {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        func drain() {
            for _ in 0 ..< 10 {
                window.contentView?.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
            }
        }

        /// `NSSplitView`'s autosave record is shared by every case in the target, and entering the
        /// mode reveals both side columns, so each case starts and ends on the shipping default:
        /// sidebar open, inspector closed.
        func resetPaneLayout() {
            if controller.isSidebarCollapsed { controller.toggleSidebar(nil) }
            if controller.isTrailingPaneOpen { controller.hideTrailingPane() }
        }

        /// Sessions are removed rather than left for the workspace's teardown to stop, because
        /// stopping one writes its transcript to the app's real conversation store.
        func tearDown() {
            if controller.contentMode == .agent { controller.setContentMode(.browse) }
            selected.contentMode = .browse
            resetPaneLayout()
            for session in agentSessions.sessions {
                agentSessions.removeSession(id: session.id)
            }
            window.orderOut(nil)
            window.contentViewController = nil
            selected.teardown()
            DatabaseManager.shared.removeSession(for: connection.id)
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: registryDirectory)
        }
    }

    /// One window hosting two connections, the second one in the background and still dialing. It
    /// owns its attempt, so a status reconcile leaves it dialing rather than failing it.
    @MainActor
    private struct TwoConnectionHarness {
        let controller: MainSplitViewController
        let foreground: ConnectionWorkspace
        let background: ConnectionWorkspace
        let agentSessions: AgentSessionRegistry
        private let window: NSWindow
        private let registryDirectory: URL

        init() {
            registryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("AgentModeWindowTests-\(UUID().uuidString)", isDirectory: true)
            agentSessions = AgentSessionRegistry(store: AgentSessionStore(directory: registryDirectory))
            foreground = Self.makeWorkspace(
                connection: TestFixtures.makeConnection(name: "Foreground"),
                phase: .idle,
                agentSessions: agentSessions
            )
            background = Self.makeWorkspace(
                connection: TestFixtures.makeConnection(name: "Background"),
                phase: .connecting,
                agentSessions: agentSessions
            )
            background.attemptToken = UUID()

            controller = MainSplitViewController(payload: nil, sessionState: nil, adopting: foreground)
            controller.workspaces.insert(background, select: false)

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

        func tearDown() {
            for workspace in [foreground, background] where workspace.contentMode == .agent {
                controller.setContentMode(.browse, for: workspace.connectionId)
            }
            if controller.isSidebarCollapsed { controller.toggleSidebar(nil) }
            if controller.isTrailingPaneOpen { controller.hideTrailingPane() }
            for session in agentSessions.sessions {
                agentSessions.removeSession(id: session.id)
            }
            window.orderOut(nil)
            window.contentViewController = nil
            background.teardown()
            foreground.teardown()
            try? FileManager.default.removeItem(at: registryDirectory)
        }

        private static func makeWorkspace(
            connection: DatabaseConnection,
            phase: ConnectionWindowPhase,
            agentSessions: AgentSessionRegistry
        ) -> ConnectionWorkspace {
            ConnectionWorkspace(
                connectionId: connection.id,
                payload: nil,
                autoConnect: false,
                payloadConnection: connection,
                session: nil,
                sessionState: nil,
                trailingPaneState: nil,
                phase: phase,
                agentSessions: agentSessions
            )
        }
    }

    /// A window of its own for a pane the connection window is not showing, so what the pane holds
    /// is laid out and can be looked at.
    @MainActor
    private struct PaneProbeWindow {
        private let window: NSWindow
        private let paneView: NSView

        init(showing paneView: NSView) {
            self.paneView = paneView
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
            window.contentView = container
            paneView.frame = container.bounds
            container.addSubview(paneView)
            window.orderFront(nil)
        }

        func settle() {
            for _ in 0 ..< 20 {
                paneView.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            }
        }

        func close() {
            paneView.removeFromSuperview()
            window.orderOut(nil)
        }
    }
}
