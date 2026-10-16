//
//  BrowseCursorCoordinator.swift
//  TablePro
//

import Foundation

/// Keeps the strip entry a window shows and the database its connection browses together. A switch
/// from the toolbar, sidebar or strip moves the cursor and the window follows once it lands; picking a
/// tab of another entry moves the window first and the cursor follows.
@MainActor
final class BrowseCursorCoordinator {
    unowned let parent: MainContentCoordinator
    /// Switches queue on the driver, so one landing after a newer request must not bring back the
    /// entry the user already left.
    private(set) var pendingRequest: Int?
    private var requestCount = 0
    /// Not asked for again on activation: dismissing the error sheet makes the window key.
    var failedFollow: String?

    init(parent: MainContentCoordinator) {
        self.parent = parent
    }

    var browsedContainer: String? {
        guard let session = parent.services.databaseManager.session(for: parent.connectionId) else { return nil }
        return WorkspaceAnchoring.browsedContainer(of: session, target: parent.tabManager.containerTarget)
    }

    /// Two windows of a torn-off connection share one cursor, and only the frontmost follows it. Nil
    /// from the window manager means no window hosts this coordinator yet.
    private var followsBrowseCursor: Bool {
        guard let frontmost = WindowManager.shared.frontmostCoordinator(for: parent.connectionId) else { return true }
        return frontmost === parent
    }

    func beginRequest() -> Int {
        requestCount &+= 1
        pendingRequest = requestCount
        return requestCount
    }

    func endRequest(_ request: Int) -> Bool {
        guard pendingRequest == request else { return false }
        pendingRequest = nil
        return true
    }

    func showBrowsedContainer() {
        parent.tabManager.show(container: browsedContainer)
    }

    /// A move from outside this window. One arriving during this window's own move belongs to an
    /// earlier switch.
    func browseContainerDidChange() {
        guard pendingRequest == nil, followsBrowseCursor else { return }
        showBrowsedContainer()
    }

    /// A pending switch counts even before the cursor moves: picking a tab of the database being
    /// left has to win over it. The saved default database stays, since picking a tab is not
    /// choosing one.
    func followVisibleContainer() {
        guard let container = parent.tabManager.visibleContainer,
              container != browsedContainer || pendingRequest != nil,
              parent.services.databaseManager.session(for: parent.connectionId)?.isConnected == true,
              followsBrowseCursor
        else { return }
        moveCursor(to: container, persist: false)
    }

    func followVisibleContainerOnActivation() {
        guard parent.tabManager.visibleContainer != failedFollow else { return }
        followVisibleContainer()
    }

    func goToEntry(_ container: String) {
        parent.tabManager.show(container: container)
        guard container != browsedContainer || pendingRequest != nil else { return }
        moveCursor(to: container, persist: true)
    }

    /// Claimed before the task starts, so a selection made in between sees it in flight and
    /// supersedes it.
    private func moveCursor(to container: String, persist: Bool) {
        failedFollow = nil
        let request = beginRequest()
        Task { @MainActor [weak self, weak parent] in
            guard let self, let parent, self.pendingRequest == request else { return }
            await parent.switchContainer(to: container, persist: persist)
            guard self.browsedContainer != container, self.pendingRequest == nil else { return }
            self.failedFollow = container
        }
    }
}
