//
//  HelpMenuBuilder.swift
//  TablePro
//

import AppKit

/// AppKit installs its own search field into whichever menu is assigned to
/// `NSApp.helpMenu`. The stock "TablePro Help" item is deliberately absent: it
/// calls `showHelp:` and fails with "Help isn't available" when no Help Book is
/// registered.
@MainActor
enum HelpMenuBuilder {
    static func build() -> NSMenuItem {
        MenuItemFactory.menu(String(localized: "Help"), items: [
            MenuItemFactory.item(
                String(localized: "TablePro Website"),
                action: #selector(AppDelegate.openWebsite(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Documentation"),
                action: #selector(AppDelegate.openDocumentation(_:))
            ),
            MenuItemFactory.item(
                String(localized: "GitHub Repository"),
                action: #selector(AppDelegate.openGitHubRepository(_:))
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Open Sample Database"),
                action: #selector(AppDelegate.openSampleDatabase(_:))
            ),
            MenuItemFactory.item(
                String(localized: "Reset Sample Database..."),
                action: #selector(AppDelegate.resetSampleDatabase(_:))
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Report an Issue"),
                action: #selector(AppDelegate.reportAnIssue(_:))
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Acknowledgements"),
                action: #selector(AppDelegate.showAcknowledgements(_:))
            )
        ])
    }
}
