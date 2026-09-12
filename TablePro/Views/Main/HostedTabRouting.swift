import AppKit
import Foundation

/// How a tab that belongs to another window is found and put in front of the reader.
///
/// Both questions go through the window layer, which is the record of what is actually on screen.
/// `MainContentCoordinator.allActiveCoordinators()` is a registry of every coordinator SwiftUI has
/// built and can hold one whose window is gone, so a reveal resolved through it can select a tab
/// nobody can see. Held as one injected value because a unit test has no windows.
@MainActor
internal struct HostedTabRouting {
    /// The coordinators for a connection that a window actually hosts.
    internal var coordinators: (UUID) -> [MainContentCoordinator]

    /// Brings one of those coordinators' tabs forward, its connection workspace with it.
    ///
    /// One window hosts several connections, so raising it is not enough: the connection the tab
    /// belongs to has to be the one that window is showing, or the reader is handed a window
    /// displaying a different connection's tabs.
    ///
    /// - Returns: whether the tab was made visible. False is the caller's cue to open the content
    ///   itself rather than leave the click doing nothing.
    internal var reveal: (MainContentCoordinator, UUID) -> Bool

    internal static let live = HostedTabRouting(
        coordinators: { WindowManager.shared.coordinators(for: $0) },
        reveal: { coordinator, tabId in
            /// This coordinator's own window, not `WindowManager.window(for:)`. Detaching a tab
            /// leaves one connection hosted by several windows, and that lookup names an arbitrary
            /// one of them, so raising it can leave the tab the reader asked for off screen while
            /// reporting success.
            guard let windowId = coordinator.windowId,
                  let window = WindowLifecycleMonitor.shared.window(for: windowId),
                  let host = window.contentViewController as? MainSplitViewController,
                  host.workspaces.contains(coordinator.connectionId) else { return false }
            host.selectHostedConnection(coordinator.connectionId)
            coordinator.tabManager.selectedTabId = tabId
            window.makeKeyAndOrderFront(nil)
            return true
        }
    )
}
