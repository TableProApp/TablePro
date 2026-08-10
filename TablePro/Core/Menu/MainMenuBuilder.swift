//
//  MainMenuBuilder.swift
//  TablePro
//

import AppKit

/// Builds the whole menu bar. Menu order follows the macOS HIG: the app menu, the
/// standard File/Edit/View menus, app-specific menus, then Window and Help.
enum MainMenuBuilder {
    static func build(keyboard: KeyboardSettings) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(AppMenuBuilder.build())
        menu.addItem(FileMenuBuilder.build(keyboard: keyboard))
        menu.addItem(EditMenuBuilder.build(keyboard: keyboard))
        menu.addItem(ViewMenuBuilder.build(keyboard: keyboard))
        menu.addItem(DatabaseMenuBuilder.build(keyboard: keyboard))
        menu.addItem(QueryMenuBuilder.build(keyboard: keyboard))

        let window = WindowMenuBuilder.build(keyboard: keyboard)
        menu.addItem(window)

        let help = HelpMenuBuilder.build()
        menu.addItem(help)

        NSApp.windowsMenu = window.submenu
        NSApp.helpMenu = help.submenu
        return menu
    }

    static func install(keyboard: KeyboardSettings) {
        NSApp.mainMenu = build(keyboard: keyboard)
    }

    static func applyShortcuts(_ keyboard: KeyboardSettings) {
        guard let menu = NSApp.mainMenu else { return }
        MainMenuKeyEquivalentSync.apply(keyboard: keyboard, to: menu)
    }
}
