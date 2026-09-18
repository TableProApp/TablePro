//
//  AppMenuBuilder.swift
//  TablePro
//

import AppKit

@MainActor
enum AppMenuBuilder {
    static func build() -> NSMenuItem {
        let servicesMenu = NSMenu(title: String(localized: "Services"))
        NSApp.servicesMenu = servicesMenu

        let services = NSMenuItem(title: String(localized: "Services"), action: nil, keyEquivalent: "")
        services.submenu = servicesMenu

        return MenuItemFactory.menu("TablePro", items: [
            MenuItemFactory.item(
                String(localized: "About TablePro"),
                action: #selector(AppDelegate.showAboutPanel(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Check for Updates…"),
                action: #selector(AppDelegate.checkForUpdates(_:))
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Integrations…"),
                action: #selector(AppDelegate.openIntegrations(_:))
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Settings…"),
                action: #selector(AppDelegate.openSettings(_:)),
                keyEquivalent: ",",
                modifiers: .command
            ),
            MenuItemFactory.separator,
            services,
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Hide TablePro"),
                action: #selector(NSApplication.hide(_:)),
                keyEquivalent: "h",
                modifiers: .command
            ),
            MenuItemFactory.item(
                String(localized: "Hide Others"),
                action: #selector(NSApplication.hideOtherApplications(_:)),
                keyEquivalent: "h",
                modifiers: [.command, .option]
            ),
            MenuItemFactory.item(
                String(localized: "Show All"),
                action: #selector(NSApplication.unhideAllApplications(_:))
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Quit TablePro"),
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q",
                modifiers: .command
            )
        ])
    }
}
