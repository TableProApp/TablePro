import AppKit
@testable import TablePro
import Testing

/// A menu-bar command with no target resolves through the responder chain, so the first responder
/// that answers the selector wins. `@objc` publishes a method to that chain whatever its access
/// level, which means a `private` action on a view controller nested inside the window can take a
/// command the window's own controller was written to handle.
///
/// That shipped: `WorkspaceRailViewController` declared `closeConnection(_:)` for its row context
/// menu, the same selector as `MainSplitViewController.closeConnection(_:)` behind File > Close
/// Connection, and the rail sits ahead of the controller in the chain. The menu item validated as
/// enabled and then did nothing at all, because the rail's handler reads `representedObject`, which
/// only its own items carry. Nothing failed to compile and no test covered it.
@Suite("Menu action selector collisions")
@MainActor
struct MenuActionSelectorCollisionTests {
    /// Every nested controller that can sit ahead of `MainSplitViewController` in a window's
    /// responder chain, paired with the commands the menu bar dispatches with no target.
    @Test(
        "No nested window controller answers a menu bar command's selector",
        arguments: [
            #selector(MainSplitViewController.closeConnection(_:)),
            #selector(MainSplitViewController.closeOtherTabs(_:)),
            #selector(MainSplitViewController.closeTabsForOtherContainers(_:)),
            #selector(MainSplitViewController.closeAllTabs(_:)),
            #selector(MainSplitViewController.saveDocument(_:)),
            #selector(MainSplitViewController.saveDocumentAs(_:)),
            #selector(MainSplitViewController.exportTables(_:)),
            #selector(MainSplitViewController.exportQueryResults(_:)),
            #selector(MainSplitViewController.backupDatabase(_:)),
            #selector(MainSplitViewController.restoreDatabase(_:))
        ]
    )
    func railDoesNotShadowMenuBarCommands(command: Selector) {
        let rail = WorkspaceRailViewController()

        #expect(
            !rail.responds(to: command),
            """
            WorkspaceRailViewController answers \(NSStringFromSelector(command)), which the menu bar \
            dispatches with no target. The rail sits ahead of MainSplitViewController in the \
            responder chain, so it would take the command and the menu item would appear to do \
            nothing. Rename the rail's action; its own items set `target` explicitly.
            """
        )
    }
}
