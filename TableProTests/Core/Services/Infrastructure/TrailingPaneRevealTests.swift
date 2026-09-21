//
//  TrailingPaneRevealTests.swift
//  TableProTests
//
//  What asking for a trailing surface does to the pane and to the connection's stored preference.
//  A surface the user picks is remembered; one the app offers, or one a mode imposes, is not. Two
//  shipped the other way: Show Assistant in Agent mode wrote the assistant into the browse preference
//  and changed nothing on screen, and the first grid click after closing a pane left on the assistant
//  opened it on the inspector and stored the inspector over the user's choice.
//

import AppKit
import Foundation
@testable import TablePro
import Testing

@Suite("Trailing pane reveal", .serialized)
@MainActor
struct TrailingPaneRevealTests {
    // MARK: - The decision

    @Test("Asking for any surface in Agent mode stores nothing, and only the result opens")
    func agentModeStoresNothing() {
        for surface in TrailingPaneSurface.allCases {
            let decision = TrailingPaneCommandResolver.reveal(surface, Self.context(mode: .agent))
            #expect(!decision.storesChoice, "\(surface)")
            #expect(decision.opensPane == (surface == .agentResult), "\(surface)")
        }
    }

    @Test("Asking for a surface while browsing stores it as the user's choice")
    func browsingStoresAChoice() {
        let context = Self.context(mode: .browse)
        #expect(
            TrailingPaneCommandResolver.reveal(.inspector, context)
                == TrailingPaneCommandResolver.Reveal(opensPane: true, storesChoice: true)
        )
        #expect(
            TrailingPaneCommandResolver.reveal(.assistant, context)
                == TrailingPaneCommandResolver.Reveal(opensPane: true, storesChoice: true)
        )
        #expect(
            TrailingPaneCommandResolver.reveal(.agentResult, context)
                == TrailingPaneCommandResolver.Reveal(opensPane: false, storesChoice: false)
        )
    }

    /// The pane would open on the inspector instead, over a question about the assistant.
    @Test("An assistant the settings took away is neither opened nor stored")
    func aiOffAssistantIsRefused() {
        let context = Self.context(mode: .browse, isAIEnabled: false)
        #expect(
            TrailingPaneCommandResolver.reveal(.assistant, context)
                == TrailingPaneCommandResolver.Reveal(opensPane: false, storesChoice: false)
        )
    }

    @Test("A grid click does not open a pane the user left on the assistant")
    func gridClickRespectsTheAssistant() {
        let context = Self.context(mode: .browse, stored: .assistant, isOpen: false)
        #expect(!TrailingPaneCommandResolver.revealsForSelection(context))
    }

    @Test("A grid click opens a closed pane left on the inspector")
    func gridClickOpensTheInspector() {
        #expect(TrailingPaneCommandResolver.revealsForSelection(Self.context(mode: .browse, isOpen: false)))
        #expect(!TrailingPaneCommandResolver.revealsForSelection(Self.context(mode: .browse, isOpen: true)))
    }

    /// With the assistant switched off the pane can only draw the inspector, so the click opens it,
    /// and the stored assistant is left for when the setting comes back.
    @Test("A grid click opens the inspector over a stored assistant the settings took away")
    func gridClickWithAIOff() {
        let context = Self.context(mode: .browse, stored: .assistant, isOpen: false, isAIEnabled: false)
        #expect(TrailingPaneCommandResolver.revealsForSelection(context))
    }

    @Test("A grid click never opens the pane in Agent mode")
    func gridClickInAgentMode() {
        for stored in TrailingPaneSurface.allCases {
            let context = Self.context(mode: .agent, stored: stored, isOpen: false)
            #expect(!TrailingPaneCommandResolver.revealsForSelection(context), "\(stored)")
        }
    }

    // MARK: - The window

    @Test("In Agent mode the pane toggle opens and closes the result column and stores nothing")
    func agentModePaneToggleActsOnTheResult() throws {
        try AIFeatureScope.enabled {
            let harness = try Harness()
            defer { harness.tearDown() }
            try harness.requireContent()
            harness.paneState.surface = .assistant
            harness.selected.contentMode = .agent

            let item = Harness.menuItem(#selector(MainSplitViewController.toggleInspector(_:)))
            #expect(harness.controller.validateMenuItem(item))
            #expect(item.title == String(localized: "Show Result"))

            harness.controller.toggleInspector(nil)
            #expect(harness.controller.isTrailingPaneOpen)
            #expect(harness.controller.inspectorPaneHost.shown === harness.selected.panes.agentResult)
            #expect(harness.paneState.surface == .assistant)
            _ = harness.controller.validateMenuItem(item)
            #expect(item.title == String(localized: "Hide Result"))

            harness.controller.toggleInspector(nil)
            #expect(!harness.controller.isTrailingPaneOpen)
            #expect(harness.paneState.surface == .assistant)
        }
    }

    /// Both routes: the View menu's command, and `showAssistant()`, which Explain with AI and Fix with
    /// AI reach from the Query menu whatever the mode.
    @Test("In Agent mode Show Assistant is dimmed and neither route stores a browse preference")
    func agentModeAssistantStoresNothing() throws {
        try AIFeatureScope.enabled {
            let harness = try Harness()
            defer { harness.tearDown() }
            try harness.requireContent()
            harness.paneState.surface = .inspector
            harness.selected.contentMode = .agent

            let item = Harness.menuItem(#selector(MainSplitViewController.toggleAssistant(_:)))
            #expect(!harness.controller.validateMenuItem(item))
            #expect(item.title == String(localized: "Show Assistant"))

            harness.controller.toggleAssistant(nil)
            harness.controller.showAssistant()

            #expect(harness.paneState.surface == .inspector)
            #expect(!harness.controller.isTrailingPaneOpen)
        }
    }

    /// Show Assistant is dimmed in Agent mode on the strength of this command reaching the
    /// conversation. The welcome window's Open in Agent Mode puts the window in the mode before its
    /// connect lands, so the browse content that sets up the command actions never mounts, and a
    /// validation that read them dimmed Focus Assistant too, leaving no command to the composer.
    @Test("Focus Assistant reaches the composer in a window that opened in Agent mode")
    func focusAssistantInAWindowOpenedInAgentMode() throws {
        try AIFeatureScope.enabled {
            let harness = try Harness(contentMode: .agent)
            defer { harness.tearDown() }
            try harness.requireContent()
            try #require(
                harness.controller.commandActions == nil,
                "The browse content mounted, so this is not the window the welcome route opens"
            )
            /// Stands in for the composer the conversation draws once a session has a provider to
            /// answer it, which a unit test has no way to configure.
            let composer = ChatComposerNSTextView.make()
            harness.selected.panes.detail.view.addSubview(composer)

            let item = Harness.menuItem(#selector(MainSplitViewController.focusAssistant(_:)))
            #expect(harness.controller.validateMenuItem(item))

            harness.controller.focusAssistant(nil)
            #expect(harness.window.firstResponder === composer)
            #expect(!harness.controller.isTrailingPaneOpen)
            #expect(harness.paneState.surface == .inspector)
        }
    }

    @Test("A grid click leaves a pane closed on the assistant closed, and the choice stored")
    func gridClickKeepsTheAssistantChoice() throws {
        try AIFeatureScope.enabled {
            let harness = try Harness()
            defer { harness.tearDown() }
            try harness.requireContent()
            harness.paneState.surface = .assistant

            harness.controller.revealInspectorForSelection()

            #expect(!harness.controller.isTrailingPaneOpen)
            #expect(harness.paneState.surface == .assistant)
        }
    }

    @Test("A grid click opens a closed pane on the inspector")
    func gridClickOpensTheInspectorPane() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        try harness.requireContent()
        harness.paneState.surface = .inspector

        harness.controller.revealInspectorForSelection()

        #expect(harness.controller.isTrailingPaneOpen)
        #expect(harness.controller.inspectorPaneHost.shown === harness.selected.panes.inspector)
        #expect(harness.paneState.surface == .inspector)
    }

    /// The header's picker writes the stored surface and nothing else. Parenting the new surface from
    /// inside that write would take the view whose segment was clicked off the window during its own
    /// action, so the window follows on the next turn of the run loop.
    @Test("A surface picked in the header is parented after the picker's action returns")
    func headerChoiceIsParentedOnTheNextTurn() throws {
        try AIFeatureScope.enabled {
            let harness = try Harness()
            defer { harness.tearDown() }
            try harness.requireContent()
            harness.controller.showInspector()
            #expect(harness.controller.inspectorPaneHost.shown === harness.selected.panes.inspector)
            /// A status event still queued from the injected session reparents the pane as well, as
            /// any transition does, and would pass this case with no observer behind the picker.
            Self.drainRunLoop()

            harness.paneState.surface = .assistant

            #expect(
                harness.controller.inspectorPaneHost.shown === harness.selected.panes.inspector,
                "The outgoing surface left the window from inside the write"
            )
            #expect(Self.turnRunLoop { harness.controller.inspectorPaneHost.shown === harness.selected.panes.assistant })
            #expect(harness.controller.isAssistantVisible)
        }
    }

    @Test("Visibility follows the surface the pane draws, not the one stored")
    func visibilityFollowsTheDrawnSurface() throws {
        try AIFeatureScope.enabled {
            let harness = try Harness()
            defer { harness.tearDown() }
            try harness.requireContent()
            harness.controller.showAssistant()
            #expect(harness.controller.isAssistantVisible)
            #expect(!harness.controller.isInspectorVisible)

            harness.selected.contentMode = .agent

            #expect(!harness.controller.isAssistantVisible)
            #expect(!harness.controller.isInspectorVisible)
            #expect(harness.paneState.surface == .assistant)
        }
    }

    // MARK: - Helpers

    private static func context(
        mode: ConnectionWorkspaceContentMode,
        stored: TrailingPaneSurface = .inspector,
        isOpen: Bool = false,
        isAIEnabled: Bool = true
    ) -> TrailingPaneCommandResolver.Context {
        TrailingPaneCommandResolver.Context(
            contentMode: mode,
            storedSurface: stored,
            isPaneOpen: isOpen,
            isAIEnabled: isAIEnabled,
            hasContent: true
        )
    }

    /// A bounded count of short turns rather than a wall-clock limit, keeping the main thread rather
    /// than yielding it, so a stored-surface change delivered on the main run loop is seen as soon as
    /// it lands and a missing one fails instead of hanging.
    private static func turnRunLoop(until condition: () -> Bool) -> Bool {
        for _ in 0 ..< 200 {
            if condition() { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        return condition()
    }

    /// Delivers whatever the main run loop already holds, so the next change a case makes is the
    /// only thing left for the window to react to.
    private static func drainRunLoop() {
        for _ in 0 ..< 20 {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
    }

    /// One connected workspace whose session the window adopts from `DatabaseManager`, the way a
    /// real connect lands. A workspace handed a session the manager does not hold is released by the
    /// first status reconcile, which the window runs as it appears and again on any status event the
    /// run loop delivers.
    ///
    /// The pane state is the connection's own, built before adoption so the window keeps it rather
    /// than building one on the app's defaults, and it writes to a suite of its own.
    @MainActor
    private struct Harness {
        let controller: MainSplitViewController
        let selected: ConnectionWorkspace
        let paneState: TrailingPaneState
        let window: NSWindow
        private let connection: DatabaseConnection
        private let defaults: UserDefaults
        private let suiteName: String

        /// `contentMode` is set before the window is built, which is how the welcome window's Open in
        /// Agent Mode lands: the mode is on before the connect, so the browse content never mounts.
        init(contentMode: ConnectionWorkspaceContentMode = .browse) throws {
            connection = TestFixtures.makeConnection(name: "Trailing", type: .mysql)
            suiteName = "TrailingPaneRevealTests.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suiteName))
            let registryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("TrailingPaneRevealTests-\(UUID().uuidString)", isDirectory: true)
            paneState = TrailingPaneState(
                connectionId: connection.id,
                defaults: defaults,
                sessionRegistry: AgentSessionRegistry(store: AgentSessionStore(directory: registryDirectory))
            )
            selected = ConnectionWorkspace(
                connectionId: connection.id,
                payload: nil,
                autoConnect: false,
                payloadConnection: connection,
                session: nil,
                sessionState: nil,
                trailingPaneState: paneState,
                phase: .connecting
            )
            selected.contentMode = contentMode
            controller = MainSplitViewController(payload: nil, sessionState: nil, adopting: selected)

            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 700),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            window.orderFront(nil)

            var session = ConnectionSession(connection: connection, driver: MockDatabaseDriver(connection: connection))
            session.status = .connected
            DatabaseManager.shared.injectSession(session, for: connection.id)
            controller.refreshFromActiveSessions()
            closePane()
        }

        /// Asked after the caller has registered `tearDown`, so a harness that failed to connect
        /// still gives its window and its injected session back.
        func requireContent() throws {
            try #require(selected.trailingPaneState === paneState, "The window replaced the connection's pane state")
            try #require(controller.currentPane == .content, "The connection has no content behind it")
        }

        static func menuItem(_ action: Selector) -> NSMenuItem {
            NSMenuItem(title: "", action: action, keyEquivalent: "")
        }

        /// `NSSplitView`'s autosave record is shared by every case in the target, so the pane is put
        /// back to the shipping default, closed, at both ends of each case.
        func closePane() {
            if controller.isTrailingPaneOpen { controller.hideTrailingPane() }
        }

        func tearDown() {
            selected.contentMode = .browse
            closePane()
            window.orderOut(nil)
            window.contentViewController = nil
            selected.teardown()
            DatabaseManager.shared.removeSession(for: connection.id)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}
