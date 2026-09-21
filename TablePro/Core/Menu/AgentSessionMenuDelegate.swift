//
//  AgentSessionMenuDelegate.swift
//  TablePro
//

import AppKit

/// The sessions the connection on screen owns, filled when the menu opens.
///
/// Filled on open rather than when the menu is built, because the list is the connection's and a
/// window changes connection without rebuilding its menu bar. It is also the one list in the app that
/// changes while the menu is closed: a reply finishing moves a session to the top, and closing one
/// from the rail takes it out of the set the command can act on.
///
/// Every entry carries no target and names its session in `representedObject`, which is the shape
/// `MainSplitViewController.agentSessionTarget(for:)` already reads, so an entry is validated and
/// carried out against the session it names rather than against the rail's highlight.
///
/// The sessions are listed in every mode, not only in Agent mode. They exist either way, and a list
/// that reported "None Available" over five live sessions would be describing the mode rather than
/// the connection; what browsing takes away is the ability to act, which the window's own validation
/// says by dimming every entry.
///
/// Built on the same shape as `ImportFormatMenuDelegate`, including the responder-chain lookup.
/// `NSMenu.delegate` is weak, so whoever builds a menu keeps the delegate alive alongside it.
@MainActor
internal final class AgentSessionMenuDelegate: NSObject, NSMenuDelegate {
    internal static let action = #selector(MainSplitViewController.openAgentSession(_:))

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let controller = NSApp.target(forAction: Self.action, to: nil, from: nil) as? MainSplitViewController
        let sessions = controller?.listedAgentSessions ?? []
        guard !sessions.isEmpty else {
            menu.addItem(MenuPlaceholder.item())
            return
        }
        let displayed = controller?.displayedAgentSessionId
        for session in sessions {
            menu.addItem(Self.item(for: session, isDisplayed: session.id == displayed))
        }
    }

    /// The tick marks the session the window is drawing, which is what the rail marks too. Outside
    /// Agent mode the window draws none, so nothing is ticked and nothing claims to be open.
    internal static func item(for session: AgentSession, isDisplayed: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: session.displayTitle, action: action, keyEquivalent: "")
        item.target = nil
        item.representedObject = session.id
        item.state = isDisplayed ? .on : .off
        return item
    }

    /// Keeps AppKit's key-equivalent search from rebuilding the menu on every modified keystroke,
    /// which would walk the responder chain for items that carry no key equivalent.
    func menuHasKeyEquivalent(
        _ menu: NSMenu,
        for event: NSEvent,
        target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
        action: UnsafeMutablePointer<Selector?>
    ) -> Bool {
        false
    }
}
