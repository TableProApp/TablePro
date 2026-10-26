import AppKit

// Built only while the Routine Debugger module is on. Items dim rather than hide when no debug tab is in front.
@MainActor
enum DebugMenuBuilder {
    static let identifier = NSUserInterfaceItemIdentifier("menu.debug")

    static var title: String {
        String(localized: "Debug")
    }

    static func build(keyboard: KeyboardSettings) -> NSMenuItem {
        let menu = MenuItemFactory.menu(title, items: [
            MenuItemFactory.item(
                String(localized: "Debug Routine…"),
                action: #selector(MainSplitViewController.chooseRoutineToDebug(_:))
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Continue"),
                action: #selector(MainSplitViewController.debugContinue(_:)),
                shortcut: .debugContinue,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Step Over"),
                action: #selector(MainSplitViewController.debugStepOver(_:)),
                shortcut: .debugStepOver,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Step Into"),
                action: #selector(MainSplitViewController.debugStepInto(_:)),
                shortcut: .debugStepInto,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Step Out"),
                action: #selector(MainSplitViewController.debugStepOut(_:)),
                shortcut: .debugStepOut,
                keyboard: keyboard
            ),
            // No default: Xcode's Command-Period is Cancel Query here.
            MenuItemFactory.item(
                String(localized: "Stop"),
                action: #selector(MainSplitViewController.debugStop(_:))
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Toggle Breakpoint"),
                action: #selector(MainSplitViewController.toggleBreakpoint(_:)),
                shortcut: .toggleBreakpoint,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Remove All Breakpoints"),
                action: #selector(MainSplitViewController.removeAllBreakpoints(_:))
            )
        ])
        menu.identifier = identifier
        return menu
    }
}
