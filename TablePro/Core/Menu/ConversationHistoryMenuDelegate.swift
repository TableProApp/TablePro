//
//  ConversationHistoryMenuDelegate.swift
//  TablePro
//

import AppKit

/// The assistant's stored conversations for the connection on screen, filled when the menu opens.
///
/// The set changes with every reply, so a list baked in when the menu bar was built would be the
/// conversations of whichever connection happened to be open at launch. This is the second place the
/// list is offered, beside the trailing pane header's own menu, and both put the choice through the
/// same window selector so the two cannot act on different connections.
///
/// Every entry carries no target and names its conversation in `representedObject`, which
/// `switchAIConversation(_:)` reads. The current one carries the menu's own checkmark, which
/// VoiceOver reads as selected.
///
/// `NSMenu.delegate` is weak, so whoever builds a menu keeps the delegate alive alongside it.
@MainActor
internal final class ConversationHistoryMenuDelegate: NSObject, NSMenuDelegate {
    internal static let action = #selector(MainSplitViewController.switchAIConversation(_:))

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let controller = NSApp.target(forAction: Self.action, to: nil, from: nil) as? MainSplitViewController
        guard let viewModel = controller?.assistantConversationModel, !viewModel.conversations.isEmpty else {
            menu.addItem(MenuPlaceholder.item())
            return
        }
        let active = viewModel.activeConversationID
        for conversation in viewModel.conversations {
            menu.addItem(Self.item(for: conversation, isActive: conversation.id == active))
        }
    }

    /// A conversation is titled from its first exchange, so one the user sent nothing in has no
    /// title at all. The pane's own list names it the same way rather than drawing a blank row.
    internal static func item(for conversation: AIConversation, isActive: Bool) -> NSMenuItem {
        let title = conversation.title.isEmpty ? String(localized: "Untitled") : conversation.title
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = nil
        item.representedObject = conversation.id
        item.state = isActive ? .on : .off
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
