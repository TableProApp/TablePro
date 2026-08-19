//
//  CloseCommandTests.swift
//  TableProTests
//
//  Command W has to close whatever window is in front. Binding it to a selector only the
//  editor window's split controller implemented left it inert in Settings, the integrations
//  activity window and every viewer, and the windows that noticed answered that selector by
//  hand. `performClose:` is the one close command every NSWindow implements and validates.
//

import AppKit
@testable import TablePro
import Testing

@MainActor
private final class NamedCloseTarget: CloseCommandNaming {
    var closeCommandTitle: String?

    init(_ title: String?) {
        closeCommandTitle = title
    }
}

@MainActor
private func fileMenu() -> NSMenu {
    let menu = MainMenuBuilder.build(keyboard: KeyboardSettings())
    return menu.items.first { $0.title == String(localized: "File") }?.submenu ?? NSMenu()
}

@Suite("Close command binding")
@MainActor
struct CloseCommandBindingTests {
    @Test("Command W is bound to the close command every window implements")
    func closeIsBoundToPerformClose() {
        let item = fileMenu().items.first { $0.keyEquivalent == "w" && $0.keyEquivalentModifierMask == .command }
        #expect(item?.action == #selector(NSWindow.performClose(_:)))
    }

    @Test("The close item still carries the customizable Close Tab shortcut")
    func closeKeepsItsShortcutIdentity() {
        let item = CloseCommandMenuDelegate.closeItem(in: fileMenu())
        #expect(item?.identifier == MenuItemFactory.identifier(for: .closeTab))
        #expect(item?.keyEquivalent == "w")
    }

    @Test("The close item leaves its target nil so each window answers for itself")
    func closeResolvesThroughTheResponderChain() {
        #expect(CloseCommandMenuDelegate.closeItem(in: fileMenu())?.target == nil)
    }

    @Test("The File menu owns the close title, so it is the menu's delegate")
    func fileMenuOwnsTheCloseTitle() {
        #expect(fileMenu().delegate is CloseCommandMenuDelegate)
    }

    /// A menu built cold has no key window to read, so it has to ship the title that suits a
    /// window with no tabs rather than the editor's.
    @Test("The close item is built as Close Window")
    func closeIsBuiltForAWindowWithoutTabs() {
        #expect(CloseCommandMenuDelegate.closeItem(in: fileMenu())?.title == String(localized: "Close Window"))
    }

    /// The built title already reads "Close Window", so asserting on it alone would pass even if
    /// the delegate never ran. This drives the delegate over the real menu instead.
    @Test("The delegate rewrites the built title from the key window")
    func delegateRewritesTheBuiltTitle() {
        let menu = fileMenu()
        let item = try? #require(CloseCommandMenuDelegate.closeItem(in: menu))
        item?.title = "stale"
        CloseCommandMenuDelegate.applyResolvedTitle(to: menu)
        #expect(item?.title == CloseCommandTitleResolver.resolvedTitle())
        #expect(item?.title != "stale")
    }

    @Test("The delegate leaves a menu with no close item alone")
    func delegateIgnoresAnUnrelatedMenu() {
        #expect(CloseCommandMenuDelegate.applyResolvedTitle(to: NSMenu()) == nil)
    }

    /// A bare editor window hosts no split controller yet, so it has no tab to close and must not
    /// offer to close one.
    @Test("An editor window with no content does not claim to close a tab")
    func bareEditorWindowDoesNotClaimATab() {
        let window = TabWindowController.makeEditorWindow()
        #expect((window as? CloseCommandNaming)?.closeCommandTitle == nil)
        #expect(CloseCommandTitleResolver.title(receiver: window, keyWindow: window) == "Close Window")
    }
}

@Suite("Close command title resolution")
@MainActor
struct CloseCommandTitleResolverTests {
    @Test("The responder that takes the command names it")
    func receiverNamesTheCommand() {
        let receiver = NamedCloseTarget("Close “localhost”")
        #expect(CloseCommandTitleResolver.title(receiver: receiver, keyWindow: nil) == "Close “localhost”")
    }

    @Test("A responder that claims the command without naming it defers to its window")
    func unnamedReceiverDefersToTheWindow() {
        let window = NamedCloseTarget("Close Tab")
        #expect(
            CloseCommandTitleResolver.title(receiver: NamedCloseTarget(nil), keyWindow: nil)
                == "Close Window"
        )
        #expect(CloseCommandTitleResolver.title(receiver: window, keyWindow: nil) == "Close Tab")
    }

    @Test("A plain window closes itself, so the command is Close Window")
    func plainWindowClosesItself() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        #expect(CloseCommandTitleResolver.title(receiver: window, keyWindow: window) == "Close Window")
    }

    @Test("With no window at all the command still has a name")
    func noWindowStillNamesTheCommand() {
        #expect(CloseCommandTitleResolver.title(receiver: nil, keyWindow: nil) == "Close Window")
    }

    /// Assigning a title that has not changed posts an item-changed notification, which makes an
    /// open menu re-lay-out and cancel tracking, so a click dismisses the menu instead of firing.
    @Test("Retitling to the same title does not touch the item")
    func retitleIsIdempotent() {
        let item = NSMenuItem(title: "Close Tab", action: nil, keyEquivalent: "")
        CloseCommandMenuDelegate.retitle(item, to: "Close Tab")
        #expect(item.title == "Close Tab")
        CloseCommandMenuDelegate.retitle(item, to: "Close Window")
        #expect(item.title == "Close Window")
    }
}
