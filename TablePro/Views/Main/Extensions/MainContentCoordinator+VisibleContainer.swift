//
//  MainContentCoordinator+VisibleContainer.swift
//  TablePro
//

import Foundation

/// Keeps the entry a window shows and the database its connection browses together.
///
/// The two move from different places. A switch from the toolbar, the sidebar or the strip moves
/// the browse cursor and the window shows that entry once it lands. Selecting a tab of another entry
/// moves the window first, because the tab is already on screen, and the cursor follows.
extension MainContentCoordinator {
    /// The entry the connection is browsing, named the way this engine names entries.
    var browsedContainer: String? {
        guard let session = services.databaseManager.session(for: connectionId) else { return nil }
        return WorkspaceAnchoring.browsedContainer(of: session, target: tabManager.containerTarget)
    }

    var newTabDatabaseName: String {
        tabManager.openingDatabase(browsing: browseDatabaseName)
    }

    /// Whether this window follows a cursor that something else moved. A connection a tab was torn
    /// off from is hosted by two windows that share one cursor, and only the one in front follows,
    /// so the window behind keeps the tabs it shows. Nil from the window manager means no window
    /// hosts this coordinator yet, and it is the only one there is.
    var followsBrowseCursor: Bool {
        guard let frontmost = WindowManager.shared.frontmostCoordinator(for: connectionId) else { return true }
        return frontmost === self
    }

    func beginCursorRequest() -> Int {
        cursorRequestCount &+= 1
        pendingCursorRequest = cursorRequestCount
        return cursorRequestCount
    }

    /// Whether the move that just finished is still the latest one this window asked for.
    func endCursorRequest(_ request: Int) -> Bool {
        guard pendingCursorRequest == request else { return false }
        pendingCursorRequest = nil
        return true
    }

    func showBrowsedContainer() {
        tabManager.show(container: browsedContainer)
    }

    /// A cursor something outside this window moved: an MCP client, a script, or the other window
    /// of a torn-off tab. A move of this window's own is applied where it lands instead, and an
    /// event that arrives while one is under way belongs to an earlier switch.
    func browseContainerDidChange() {
        guard pendingCursorRequest == nil, followsBrowseCursor else { return }
        showBrowsedContainer()
    }

    /// The selection took the window to another entry, so the connection browses it too.
    ///
    /// The saved default database stays: picking a tab is not choosing a database. A switch that
    /// fails leaves the entry on screen with the error, because its tabs are still the user's work
    /// and a database that cannot be browsed is no reason to hide them.
    ///
    /// A switch still on its way counts even when the cursor has not moved yet: picking a tab of the
    /// database being left, before the switch away lands, has to win over it.
    ///
    /// A window that is not the connection's frontmost does not move the cursor; it does once it
    /// becomes key.
    func followVisibleContainer() {
        guard let container = tabManager.visibleContainer,
              container != browsedContainer || pendingCursorRequest != nil,
              services.databaseManager.session(for: connectionId)?.isConnected == true,
              followsBrowseCursor
        else { return }
        moveCursor(to: container, persist: false)
    }

    /// Claimed before the task is scheduled, so a selection made before it starts sees it in flight
    /// and supersedes it, and a superseded task never switches at all. A failure is remembered so the
    /// window coming back to the front, which is what dismissing the error does, does not ask again.
    private func moveCursor(to container: String, persist: Bool) {
        failedCursorFollow = nil
        let request = beginCursorRequest()
        Task { @MainActor [weak self] in
            guard let self, self.pendingCursorRequest == request else { return }
            await self.switchContainer(to: container, persist: persist)
            guard self.browsedContainer != container, self.pendingCursorRequest == nil else { return }
            self.failedCursorFollow = container
        }
    }

    /// Two windows of one connection share its cursor, so the one the user comes back to may show an
    /// entry the other window has since moved the cursor away from. The window in front decides what
    /// the connection browses. A container whose switch just failed is not asked for again on every
    /// activation: dismissing the error makes the window key, and retrying there raised it again.
    func followVisibleContainerOnActivation() {
        guard tabManager.visibleContainer != failedCursorFollow else { return }
        followVisibleContainer()
    }

    /// Going to one of this connection's strip entries. Its tabs are this window's own, so they come
    /// forward at once, and the object browser follows once the switch lands.
    func goToEntry(_ container: String) {
        tabManager.show(container: container)
        guard container != browsedContainer || pendingCursorRequest != nil else { return }
        moveCursor(to: container, persist: true)
    }
}
