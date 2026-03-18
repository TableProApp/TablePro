//
//  TextView+Menu.swift
//  CodeEditSourceEditor
//
//  Created by Lukas Pistrol on 25.05.22.
//

import AppKit
import CodeEditTextView

extension TextView {

    /// Setup context menus
    func setupMenus() {
        guard let menu = menu else { return }
        self.menu = helpMenu(menu)
        self.menu = codeMenu(menu)
        self.menu = gitMenu(menu)
        self.menu = removeMenus(menu)
    }

    func helpMenu(_ menu: NSMenu) -> NSMenu {
        menu.insertItem(withTitle: "Jump To Definition",
                        action: nil,
                        keyEquivalent: "",
                        at: 0)

        menu.insertItem(withTitle: "Show Code Actions",
                        action: nil,
                        keyEquivalent: "",
                        at: 1)

        menu.insertItem(withTitle: "Show Quick Help",
                        action: nil,
                        keyEquivalent: "",
                        at: 2)

        menu.insertItem(.separator(), at: 3)

        return menu
    }

    func codeMenu(_ menu: NSMenu) -> NSMenu {

        menu.insertItem(withTitle: "Refactor",
                        action: nil,
                        keyEquivalent: "",
                        at: 4)

        menu.insertItem(withTitle: "Find",
                        action: nil,
                        keyEquivalent: "",
                        at: 5)

        menu.insertItem(withTitle: "Navigate",
                        action: nil,
                        keyEquivalent: "",
                        at: 6)

        menu.insertItem(.separator(), at: 7)

        return menu
    }

    func gitMenu(_ menu: NSMenu) -> NSMenu {
        menu.insertItem(withTitle: "Show Last Change For Line",
                        action: nil,
                        keyEquivalent: "",
                        at: 8)

        menu.insertItem(withTitle: "Create Code Snippet...",
                        action: nil,
                        keyEquivalent: "",
                        at: 9)

        menu.insertItem(withTitle: "Add Pull Request Discussion to Current Line",
                        action: nil,
                        keyEquivalent: "",
                        at: 10)

        menu.insertItem(.separator(), at: 11)

        return menu
    }

    /// This removes the default menu items in the context menu based on their name..
    ///
    /// The only problem currently is how well it would work with other languages.
    func removeMenus(_ menu: NSMenu) -> NSMenu {
        let removeItemsContaining = [
            // Learn Spelling
            "_learnSpellingFromMenu:",

            // Ignore Spelling
            "_ignoreSpellingFromMenu:",

            // Spelling suggestion
            "_changeSpellingFromMenu:",

            // Search with Google
            "_searchWithGoogleFromMenu:",

            // Share, Font, Spelling and Grammar, Substitutions, Transformations
            // Speech, Layout Orientation
            "submenuAction:",

            // Lookup, Translate
            "_rvMenuItemAction"
        ]

        for item in menu.items {
            if let itemAction = item.action {
                if removeItemsContaining.contains(String(describing: itemAction)) {
                    // Get localized item name, and remove it.
                    let index = menu.indexOfItem(withTitle: item.title)
                    if index >= 0 {
                        menu.removeItem(at: index)
                    }
                }
            }
        }

        return menu
    }
}
