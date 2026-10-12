//
//  SidebarAddButton.swift
//  TablePro
//

import AppKit
import SwiftUI

@MainActor
internal enum SidebarCreationMenuBuilder {
    internal static func selector(for command: SidebarMenuCommand) -> Selector? {
        switch command {
        case .createTable:
            return #selector(MainSplitViewController.createNewTable(_:))
        case .createView:
            return #selector(MainSplitViewController.createNewView(_:))
        case .createSchema:
            return #selector(MainSplitViewController.createSchema(_:))
        case .createDatabase:
            return #selector(MainSplitViewController.createNewDatabase(_:))
        case .tableFolder(.create(.browsed)):
            return #selector(MainSplitViewController.createTableFolder(_:))
        default:
            return nil
        }
    }

    // No target: each item reaches the window's controller through the responder chain, which
    // validates it exactly as it validates the Database menu item with the same selector.
    internal static func fill(_ menu: NSMenu, with sections: [DatabaseTreeMenuSection]) {
        menu.removeAllItems()
        menu.autoenablesItems = true
        let groups = sections
            .map { section in section.items.compactMap { makeItem($0) } }
            .filter { !$0.isEmpty }
        for (index, items) in groups.enumerated() {
            if index > 0 {
                menu.addItem(.separator())
            }
            for item in items {
                menu.addItem(item)
            }
        }
    }

    private static func makeItem(_ item: DatabaseTreeMenuItem) -> NSMenuItem? {
        guard case .command(let entry) = item, let action = selector(for: entry.command) else { return nil }
        return NSMenuItem(title: entry.title, action: action, keyEquivalent: "")
    }
}

internal struct SidebarAddButton: NSViewRepresentable {
    let sections: @MainActor () -> [DatabaseTreeMenuSection]
    let isEnabled: Bool

    func makeNSView(context: Context) -> SidebarPullDownButton {
        let button = SidebarPullDownButton(
            symbolName: "plus",
            label: String(localized: "Add"),
            identifier: "sidebar-add"
        ) { _ in }
        configure(button)
        return button
    }

    func updateNSView(_ button: SidebarPullDownButton, context: Context) {
        configure(button)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SidebarPullDownButton, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    private func configure(_ button: SidebarPullDownButton) {
        let sections = sections
        button.fill = { menu in SidebarCreationMenuBuilder.fill(menu, with: sections()) }
        button.isEnabled = isEnabled
    }
}

internal struct FavoritesAddButton: NSViewRepresentable {
    let perform: @MainActor (FavoritesMenuCommand) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(perform: perform)
    }

    func makeNSView(context: Context) -> SidebarPullDownButton {
        let coordinator = context.coordinator
        return SidebarPullDownButton(
            symbolName: "plus",
            label: String(localized: "Add"),
            identifier: "sidebar-favorites-add"
        ) { [weak coordinator] menu in
            guard let coordinator else { return }
            SidebarMenuBuilder.fill(
                menu,
                with: FavoritesMenuSpec.creationSections(),
                target: coordinator,
                action: #selector(Coordinator.performCommand(_:))
            )
        }
    }

    func updateNSView(_ button: SidebarPullDownButton, context: Context) {
        context.coordinator.perform = perform
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SidebarPullDownButton, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    @MainActor
    internal final class Coordinator: NSObject {
        internal var perform: @MainActor (FavoritesMenuCommand) -> Void

        internal init(perform: @escaping @MainActor (FavoritesMenuCommand) -> Void) {
            self.perform = perform
        }

        @objc
        internal func performCommand(_ sender: NSMenuItem) {
            guard let box = sender.representedObject as? SidebarMenuCommandBox<FavoritesMenuCommand> else { return }
            perform(box.command)
        }
    }
}
