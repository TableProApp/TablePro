//
//  MainMenuBuilder.swift
//  TablePro
//

import AppKit

/// Builds the whole menu bar. Menu order follows the macOS HIG: the app menu, the
/// standard File/Edit/View menus, app-specific menus, then Window and Help.
@MainActor
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

    /// The menu bar's key equivalents are one global resource, so exactly one function
    /// computes them, from the keyboard settings and the key window's text-focus state.
    /// A rebind, a settings sync, a focus transition and a key-window change all route
    /// here, so no two writers can disagree, and the result is idempotent: applying it
    /// twice for the same inputs produces the same menu.
    static func syncKeyEquivalents() {
        syncKeyEquivalents(keyboard: AppSettingsManager.shared.keyboard)
    }

    static func syncKeyEquivalents(keyboard: KeyboardSettings) {
        guard let menu = NSApp.mainMenu else { return }
        syncKeyEquivalents(keyboard: keyboard, actions: keyWindowCommandActions(), to: menu)
    }

    /// `actions` is nil whenever the key window owns none (the welcome window, Settings,
    /// a window that is still connecting, or no key window at all). Nothing yields then,
    /// which restores every key equivalent a text field had stripped.
    static func syncKeyEquivalents(
        keyboard: KeyboardSettings,
        actions: MainContentCommandActions?,
        to menu: NSMenu
    ) {
        MainMenuKeyEquivalentSync.applyTextInputYield(
            keyboard: keyboard,
            yields: { action, key in actions?.yieldsToFocusedTextInput(action, boundKey: key) ?? false },
            to: menu
        )
    }

    private static func keyWindowCommandActions() -> MainContentCommandActions? {
        guard let window = NSApp.keyWindow else { return nil }
        return MainContentCoordinator.coordinator(forWindow: window)?.commandActions
    }
}
