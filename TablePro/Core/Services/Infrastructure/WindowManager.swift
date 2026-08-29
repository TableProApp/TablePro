//
//  WindowManager.swift
//  TablePro
//

import AppKit
import os
import SwiftUI

@MainActor
internal final class WindowManager {
    nonisolated private static let lifecycleLogger = Logger(subsystem: "com.TablePro", category: "NativeTabLifecycle")

    internal static let shared = WindowManager()

    private var controllers: [ObjectIdentifier: TabWindowController] = [:]
    private var closeObservers: [ObjectIdentifier: NSObjectProtocol] = [:]

    private init() {}

    // MARK: - Open

    /// One window hosts every connection, so an open reuses the window that already exists and
    /// only adds a workspace to it. A second window is created solely when there is none.
    internal func openTab(payload: EditorTabPayload, activate: Bool = true, autoConnect: Bool = false) {
        /// Before the window exists, and whether or not the caller wants it in front: a window on
        /// screen is user-facing work, and a process serving MCP in the background has no menu bar
        /// to give it until it stops being one.
        AppActivationPolicyController.shared.enterForeground()
        if let host = host(for: payload.connectionId) {
            /// A connection the window already hosts still has to honour the payload, because a
            /// payload names a tab to open, not just a connection to show. Adopting the
            /// workspace alone would silently drop the table the caller asked for.
            if let existing = host.workspaces.workspace(for: payload.connectionId) {
                host.workspaces.select(payload.connectionId)
                existing.open(payload)
            } else {
                host.adoptWorkspace(payload: payload, autoConnect: autoConnect)
            }
            if activate {
                host.view.window?.makeKeyAndOrderFront(nil)
                AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
            }
            Self.lifecycleLogger.info(
                "[open] WindowManager adopted into existing window connId=\(payload.connectionId, privacy: .public)"
            )
            return
        }
        openInNewWindow(payload: payload, activate: activate, autoConnect: autoConnect)
    }

    /// A host is any visible window whose content controller can hold workspaces. Selecting by the
    /// `main-` identifier prefix also matched the inspector window, whose controller is a different
    /// type, so the cast failed and an inspector in front made every open create a second window.
    private func frontmostHost() -> MainSplitViewController? {
        if let key = NSApp.keyWindow, key.isVisible,
           let host = key.contentViewController as? MainSplitViewController {
            return host
        }
        return NSApp.windows
            .filter(\.isVisible)
            .compactMap { $0.contentViewController as? MainSplitViewController }
            .first
    }

    /// The window already hosting this connection wins, so opening a table for it never lands in
    /// a different window that merely happened to be in front. The choice itself is
    /// `WindowHostSelection`, which is pure and tested.
    private func host(for connectionId: UUID) -> MainSplitViewController? {
        let candidates = hosts()
        guard !candidates.isEmpty else { return nil }
        let frontmost = frontmostHost()
        let frontmostIndex = frontmost.flatMap { front in
            candidates.firstIndex { $0 === front }
        }
        guard let index = WindowHostSelection.hostIndex(
            forConnection: connectionId,
            hostedConnections: candidates.map(\.workspaces.connectionIds),
            frontmostIndex: frontmostIndex
        ) else { return nil }
        return candidates.indices.contains(index) ? candidates[index] : nil
    }

    /// Moves a connection the window already hosts into a window of its own, carrying its session,
    /// tabs and unsaved work with it. The reverse of the single-window model's default, and the
    /// workflow it took away: `NSWindow`'s own Move Tab to New Window cannot express it, because a
    /// connection is not a window tab here.
    ///
    /// Refused for a window's last connection, where it would close the window and open an
    /// identical one. The rail hides the command in that case rather than dimming it.
    internal func canMoveToNewWindow(connectionId: UUID) -> Bool {
        let owning = hosts().filter { $0.workspaces.contains(connectionId) }
        /// Withheld while the connection is split across windows by a detached tab. Both this and
        /// `moveToNewWindow` resolve the host by connection id alone, so with two of them the
        /// command is offered in one rail and acts on the other's workspace.
        guard owning.count == 1, let host = owning.first else { return false }
        return host.workspaces.count > 1
    }

    /// Removing and inserting both move the registry's selection, and the registry is what tells the
    /// window to repaint. Repainting here as well ran the whole switch twice for one action.
    internal func moveToNewWindow(connectionId: UUID) {
        guard canMoveToNewWindow(connectionId: connectionId),
              let host = hosts().first(where: { $0.workspaces.contains(connectionId) }),
              let workspace = host.workspaces.remove(connectionId) else { return }

        let payload = EditorTabPayload(connectionId: connectionId, intent: .restoreOrDefault)
        guard openStandaloneWindow(payload: payload, adopting: workspace) else {
            /// The window never built, and the connection is out of its old registry. Putting it
            /// back is the only alternative to it being hosted by no window at all.
            host.workspaces.insert(workspace)
            return
        }
    }

    /// Moves one tab into a window of its own, the way a window tab is dragged out of its group.
    ///
    /// The connection is then hosted by two windows. That is a state the app already had before
    /// 0.65.0 and kept the machinery for: the session, its driver and its saved tab set are the
    /// connection's, not the window's, so both windows share one `ConnectionSession` and the close
    /// path already refuses to disconnect while `hasOpenWindow(for:)` still answers true. What each
    /// window owns is a `QueryTabManager`, and the tab moves between those.
    ///
    /// The new window is given the tab through a pre-built session state rather than through the
    /// payload, so nothing re-opens or re-restores it, and the intent is `.openContent` because
    /// `.restoreOrDefault` would fill the new window with the whole saved set.
    @discardableResult
    internal func openTabInNewWindow(connectionId: UUID, tabId: UUID) -> Bool {
        /// Resolved by which workspace actually holds the tab. After one detach the connection is
        /// hosted twice, and the singular lookup names an arbitrary one of them: asking it for a
        /// tab that lives in the other window fails a move the user did ask for.
        guard let origin = workspaces(for: connectionId).first(where: { workspace in
            workspace.sessionState?.tabManager.tabs.contains { $0.id == tabId } ?? false
        }),
            let sourceState = origin.sessionState,
            let tab = sourceState.tabManager.tabs.first(where: { $0.id == tabId }),
            let connection = DatabaseManager.shared.activeSessions[connectionId]?.connection
        else { return false }

        let payload = EditorTabPayload(
            connectionId: connectionId,
            tabType: tab.tabType,
            tableName: tab.tableContext.tableName,
            databaseName: tab.tableContext.databaseName,
            schemaName: tab.tableContext.schemaName,
            sourceFileURL: tab.content.sourceFileURL,
            tabTitle: tab.title,
            intent: .openContent
        )
        /// Enriched, not raw. A query tab's live caret and selection are held by the coordinator
        /// that has it mounted and are written onto the tab only for persistence, so moving the raw
        /// value drops the user's position in the editor.
        let moved = sourceState.coordinator.enrichedForPersistence(tab)
        let state = SessionStateFactory.create(connection: connection, payload: nil)
        state.tabManager.tabs = [moved]
        state.tabManager.selectedTabId = moved.id

        /// The rows the tab already loaded live in its `TabSession`, which belongs to the
        /// coordinator's registry rather than to the tab. Without handing it over the new window
        /// shows an empty grid it will not refill: the tab's `lastExecutedAt` is already set, so
        /// nothing asks for the page again.
        if let liveSession = sourceState.coordinator.tabSessionRegistry.session(for: tabId) {
            state.coordinator.tabSessionRegistry.register(liveSession)
        }

        /// The destination has to be told a tab arrived. Its coordinator was built with no payload
        /// and `selectedTabId` is set before anything observes the manager, so the switch that
        /// normally prepares an incoming tab never runs: `toolbarState.isTableTab` stayed false and
        /// `changeManager` kept empty table, column and primary-key metadata, which leaves Find and
        /// Filter disabled and a later edit unable to name the row it is saving. This is that same
        /// preparation, with no outgoing tab to put away.
        state.coordinator.handleTabChange(from: nil, to: moved.id, tabs: [moved])
        SessionStateFactory.registerPending(state, for: payload.id)

        guard let window = buildWindow(payload: payload, sessionState: state, autoConnect: false) else {
            /// The pending entry expires on its own, but leaving it for the timeout would let the
            /// next window opened for this connection adopt a session state holding a tab that
            /// never left its old window.
            SessionStateFactory.removePending(for: payload.id)
            return false
        }

        /// Removed only once the window exists. `closeTab` is the move-out primitive here: it takes
        /// the tab out of the array and settles the selection, and unlike the user's own close it
        /// neither prompts nor clears anything from disk.
        sourceState.coordinator.tabSessionRegistry.unregister(id: tabId)
        sourceState.tabManager.closeTab(id: tabId)

        (window.contentViewController as? MainSplitViewController)?.hostsDetachedTab = true

        /// A file's window mapping follows its tab, or reopening the file focuses the window the
        /// tab has left and does nothing there.
        if let sourceURL = tab.content.sourceFileURL,
           let windowId = (window.contentViewController as? MainSplitViewController)?
           .workspaces.workspace(for: connectionId)?.sessionState?.coordinator.windowId {
            WindowLifecycleMonitor.shared.registerSourceFile(sourceURL, windowId: windowId)
        }

        /// Ordered front as a window of its own. Left at `.automatic` the system preference can
        /// merge it straight back into the tab group it was asked to leave, which is the trap
        /// `openStandaloneWindow` already documents.
        window.tabbingMode = .disallowed
        window.makeKeyAndOrderFront(nil)
        window.tabbingMode = .automatic
        AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
        return true
    }

    private func buildWindow(
        payload: EditorTabPayload,
        sessionState: SessionStateFactory.SessionState?,
        autoConnect: Bool,
        adopting workspace: ConnectionWorkspace? = nil
    ) -> NSWindow? {
        let controller = TabWindowController(
            payload: payload,
            sessionState: sessionState,
            autoConnect: autoConnect,
            adopting: workspace
        )
        guard let window = controller.window else {
            Self.lifecycleLogger.error(
                "[open] WindowManager.openTab failed: controller has no window payloadId=\(payload.id, privacy: .public)"
            )
            SessionStateFactory.removePending(for: payload.id)
            return nil
        }
        retain(controller: controller, window: window)
        return window
    }

    /// A connection moved out of a shared window lands in a window of its own.
    ///
    /// It shares only the building with `openInNewWindow`, never the presentation: that one joins
    /// the existing tab group on purpose, which is what made Open in New Window produce a second
    /// native tab of the very window it was asked to leave. It also brings its own session state,
    /// so nothing is built for it here.
    @discardableResult
    private func openStandaloneWindow(payload: EditorTabPayload, adopting workspace: ConnectionWorkspace) -> Bool {
        guard let window = buildWindow(
            payload: payload,
            sessionState: nil,
            autoConnect: false,
            adopting: workspace
        ) else { return false }

        /// The system preference can tab a window on its own, without anyone asking AppKit to.
        /// Refused for the moment the window is placed, then allowed again, because a window moved
        /// out by hand is still entitled to be merged back by hand.
        window.tabbingMode = .disallowed
        window.makeKeyAndOrderFront(nil)
        AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
        window.tabbingMode = .automatic
        return true
    }

    private func openInNewWindow(payload: EditorTabPayload, activate: Bool, autoConnect: Bool) {
        let t0 = Date()
        Self.lifecycleLogger.info(
            "[open] WindowManager.openTab start payloadId=\(payload.id, privacy: .public) connId=\(payload.connectionId, privacy: .public) intent=\(String(describing: payload.intent), privacy: .public) skipAutoExecute=\(payload.skipAutoExecute) activate=\(activate)"
        )

        let resolvedConnection = DatabaseManager.shared.activeSessions[payload.connectionId]?.connection
        var preCreatedSessionState: SessionStateFactory.SessionState?
        if let resolvedConnection {
            let state = SessionStateFactory.create(connection: resolvedConnection, payload: payload)
            SessionStateFactory.registerPending(state, for: payload.id)
            preCreatedSessionState = state
        }

        guard let window = buildWindow(
            payload: payload,
            sessionState: preCreatedSessionState,
            autoConnect: autoConnect
        ) else {
            /// The window this promoted for never arrived, and nothing else will recount: only a
            /// window closing does, and there is no window to close.
            AppActivationPolicyController.shared.reevaluate()
            return
        }

        // orderFront before addTabbedWindow avoids a synchronous full-tree
        // SwiftUI layout pass that adds 700-900ms per open.
        let tabbingId = window.tabbingIdentifier

        if let sibling = findSibling(tabbingIdentifier: tabbingId, excluding: window) {
            let target = sibling.tabbedWindows?.last ?? sibling
            target.addTabbedWindow(window, ordered: .above)
            if activate {
                window.makeKeyAndOrderFront(nil)
            }
            Self.lifecycleLogger.info(
                "[open] WindowManager joined existing tab group payloadId=\(payload.id, privacy: .public) tabbingId=\(tabbingId, privacy: .public)"
            )
        } else {
            if activate {
                window.makeKeyAndOrderFront(nil)
                AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
            } else {
                window.orderFront(nil)
            }
            Self.lifecycleLogger.info(
                "[open] WindowManager standalone window payloadId=\(payload.id, privacy: .public) tabbingId=\(tabbingId, privacy: .public)"
            )
        }

        Self.lifecycleLogger.info(
            "[open] WindowManager.openTab done payloadId=\(payload.id, privacy: .public) elapsedMs=\(Int(Date().timeIntervalSince(t0) * 1_000))"
        )
    }

    // MARK: - Retention

    private func retain(controller: TabWindowController, window: NSWindow) {
        let key = ObjectIdentifier(window)
        controllers[key] = controller
        closeObservers[key] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.release(windowKey: key)
            }
        }
    }

    private func release(windowKey: ObjectIdentifier) {
        if let observer = closeObservers.removeValue(forKey: windowKey) {
            NotificationCenter.default.removeObserver(observer)
        }
        controllers.removeValue(forKey: windowKey)
    }

    // MARK: - Helpers

    internal func hasOpenWindow(for connectionId: UUID) -> Bool {
        hosts().contains { $0.workspaces.contains(connectionId) }
    }

    /// The coordinator a connection is actually using, found through the window hosting it.
    ///
    /// `MainContentCoordinator.activeCoordinators` cannot answer this. It is keyed by coordinator
    /// instance and also holds throwaway instances SwiftUI built and discarded while re-evaluating a
    /// body, so picking the first one with a matching connection id returns one of those about as
    /// often as the real one: no tabs, no command surface, and every command silently does nothing.
    /// A window's workspace registry names exactly one coordinator per connection.
    internal func coordinator(for connectionId: UUID) -> MainContentCoordinator? {
        hosts()
            .lazy
            .compactMap { $0.workspaces.workspace(for: connectionId)?.sessionState?.coordinator }
            .first
    }

    private func hosts() -> [MainSplitViewController] {
        controllers.values.compactMap { $0.window?.contentViewController as? MainSplitViewController }
    }

    /// Every connection window from the moment it is created, including one that has not
    /// connected yet. `WindowLifecycleMonitor` only learns about a window once its content
    /// view mounts, which needs a live session.
    internal func allConnectionIds() -> Set<UUID> {
        Set(hosts().flatMap(\.workspaces.connectionIds))
    }

    /// Every hosted connection's workspace, which is where the containers it has open live and
    /// where its connection record survives the end of its session.
    internal func hostedWorkspaces() -> [ConnectionWorkspace] {
        hosts().flatMap(\.workspaces.workspaces)
    }

    internal func workspace(for connectionId: UUID) -> ConnectionWorkspace? {
        workspaces(for: connectionId).first
    }

    /// Every window hosting this connection, in window order.
    ///
    /// A connection is hosted by more than one window as soon as a tab is torn off into its own
    /// (`openTabInNewWindow`). The single-workspace lookup above then names an arbitrary one of
    /// them, so anything that has to see all of a connection's tabs, or act on all of them, asks
    /// this instead. One window still holds at most one workspace per connection, which is why
    /// the per-window registry stays keyed by connection id.
    internal func workspaces(for connectionId: UUID) -> [ConnectionWorkspace] {
        hosts().compactMap { $0.workspaces.workspace(for: connectionId) }
    }

    internal func coordinators(for connectionId: UUID) -> [MainContentCoordinator] {
        workspaces(for: connectionId).compactMap { $0.sessionState?.coordinator }
    }

    /// The window hosting this connection, whatever state it is in.
    ///
    /// Visibility is not the test: a miniaturized window still hosts its connections, so filtering
    /// on `isVisible` answered nothing for one and left the connection unreachable from the strip
    /// and from a close command. `host(for:)` is a different question, "which window should adopt
    /// this connection", and falls back to the frontmost window for one nobody hosts yet.
    internal func window(for connectionId: UUID) -> NSWindow? {
        hostingController(for: connectionId)?.window
    }

    /// The connection the window hosting `connectionId` is showing, when that is a different one.
    ///
    /// A close reveals the work it is about to destroy before asking, which switches the window to
    /// that connection. An answer that closes nothing has to put the user back, so both close paths
    /// take this first and hand it to `show(_:inWindowHosting:)` afterwards.
    internal func shownConnection(besides connectionId: UUID) -> UUID? {
        guard let host = window(for: connectionId)?.contentViewController as? MainSplitViewController
        else { return nil }
        let showing = host.workspaces.selectedConnectionId
        return showing == connectionId ? nil : showing
    }

    internal func show(_ connectionId: UUID?, inWindowHosting hostedId: UUID) {
        guard let connectionId,
              let host = window(for: hostedId)?.contentViewController as? MainSplitViewController,
              host.workspaces.contains(connectionId)
        else { return }
        host.selectHostedConnection(connectionId)
    }

    internal func hostingController(for connectionId: UUID) -> NSWindowController? {
        controllers.values.first { controller in
            guard let host = controller.window?.contentViewController as? MainSplitViewController
            else { return false }
            return host.workspaces.contains(connectionId)
        }
    }

    internal func connectionIdsRetainingRestoreIntent() -> [UUID] {
        var seen = Set<UUID>()
        return controllers.values
            .compactMap { $0.window?.contentViewController as? MainSplitViewController }
            .flatMap(\.connectionIdsRetainingRestoreIntent)
            .filter { seen.insert($0).inserted }
    }

    /// Closing a connection removes its workspace. The window itself only closes once it has no
    /// connection left to show, because it is no longer the connection's window.
    /// A miniaturized window still hosts its connections, so `isVisible` is not the test: closing a
    /// connection while its window was minimized left the workspace in place with no way to reach it.
    internal func closeWindow(for connectionId: UUID) {
        let targets = controllers.values.compactMap { controller -> (NSWindow, MainSplitViewController)? in
            guard let window = controller.window,
                  let host = window.contentViewController as? MainSplitViewController,
                  host.workspaces.contains(connectionId) else { return nil }
            return (window, host)
        }
        guard !targets.isEmpty else { return }

        SessionTabStatePersister().persistTabState(for: connectionId)

        var closedAnywhere = false
        for (window, host) in targets {
            guard let removed = host.workspaces.remove(connectionId) else { continue }
            removed.teardown()
            closedAnywhere = true
            /// No repaint here: `remove` already moved the registry's selection to a neighbour,
            /// and that is what repaints the window.
            if host.workspaces.isEmpty {
                window.close()
            }
        }
        guard closedAnywhere else { return }

        /// Closing a connection ends it. The window used to do that on its way out, which covered
        /// this while a connection owned its window; a connection closed out of a window that stays
        /// open reached nothing, and its driver, tunnel and health monitor ran on unreferenced.
        WindowLifecycleMonitor.shared.unregisterWindows(for: connectionId)
        Task { await DatabaseManager.shared.disconnectSession(connectionId) }
    }

    internal static func isMainWindow(_ window: NSWindow) -> Bool {
        guard let raw = window.identifier?.rawValue else { return false }
        return raw == "main" || raw.hasPrefix("main-")
    }

    /// One identifier for every app window. Editor tabs live in the window's own strip now, so
    /// the native tab bar is free to mean what AppKit means by it: several app windows the user
    /// chose to group. That is also what makes Merge All Windows work.
    internal static let mainTabbingIdentifier = "com.TablePro.main"

    private func findSibling(tabbingIdentifier: String, excluding: NSWindow) -> NSWindow? {
        NSApp.windows.first { candidate in
            candidate !== excluding
                && Self.isMainWindow(candidate)
                && candidate.isVisible
                && candidate.tabbingIdentifier == tabbingIdentifier
        }
    }
}
