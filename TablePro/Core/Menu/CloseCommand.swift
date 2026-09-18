//
//  CloseCommand.swift
//  TablePro
//

import AppKit

/// A responder that answers `performClose:` and calls the thing it closes something other than
/// a window. Xcode, Terminal and Finder all ship one Close item on Command W and retitle it from
/// the front window, because AppKit retitles nothing itself: a menu built with a `performClose:`
/// item keeps whatever title it was built with even once the key window joins a tab group.
@MainActor
internal protocol CloseCommandNaming: AnyObject {
    /// `nil` claims the command without renaming it, which lets the resolver fall back to the
    /// window the responder lives in rather than inventing a name for it.
    var closeCommandTitle: String? { get }
}

/// Resolves the File menu's Close title from whoever would receive `performClose:`.
///
/// `performClose:` travels the responder chain like any other action, so the receiver is the
/// nearest responder that claims it: the connections strip while it holds the keyboard, otherwise
/// the key window. Every `NSWindow` implements and validates the selector, so the command can
/// never resolve to nothing, which is what the app-specific selector it replaced could do.
@MainActor
internal enum CloseCommandTitleResolver {
    internal static var windowTitle: String { String(localized: "Close Window") }

    internal static func title(receiver: Any?, keyWindow: NSWindow?) -> String {
        if let named = (receiver as? CloseCommandNaming)?.closeCommandTitle { return named }
        if let named = (keyWindow as? CloseCommandNaming)?.closeCommandTitle { return named }
        return windowTitle
    }

    internal static func resolvedTitle() -> String {
        title(
            receiver: NSApp.target(forAction: #selector(NSWindow.performClose(_:)), to: nil, from: nil),
            keyWindow: NSApp.keyWindow
        )
    }
}

/// The single owner of that title.
///
/// AppKit asks only the responder it resolved an item to for validation, so a title written from
/// `validateMenuItem(_:)` would be left stale by every window that does not claim the command.
/// The menu's own delegate runs whichever window is key, which is the one place that holds for
/// all of them.
@MainActor
internal final class CloseCommandMenuDelegate: NSObject, NSMenuDelegate {
    /// The action, not an identifier: `MenuItemFactory` already stamps the identifier with the
    /// shortcut this item carries, and `MainMenuKeyEquivalentSync` reads that back when the user
    /// rebinds Command W.
    internal static func closeItem(in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.action == #selector(NSWindow.performClose(_:)) }
    }

    internal func menuNeedsUpdate(_ menu: NSMenu) {
        Self.applyResolvedTitle(to: menu)
    }

    @discardableResult
    internal static func applyResolvedTitle(to menu: NSMenu) -> NSMenuItem? {
        guard let item = closeItem(in: menu) else { return nil }
        retitle(item, to: CloseCommandTitleResolver.resolvedTitle())
        return item
    }

    /// Assigning a title that has not changed still posts an item-changed notification, which makes
    /// an open menu re-lay-out and cancel tracking.
    internal static func retitle(_ item: NSMenuItem, to title: String) {
        guard item.title != title else { return }
        item.title = title
    }
}
