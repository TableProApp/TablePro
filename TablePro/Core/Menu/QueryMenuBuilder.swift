//
//  QueryMenuBuilder.swift
//  TablePro
//

import AppKit

@MainActor
enum QueryMenuBuilder {
    static func build(keyboard: KeyboardSettings) -> NSMenuItem {
        MenuItemFactory.menu(String(localized: "Query"), items: [
            MenuItemFactory.item(
                String(localized: "Execute Query"),
                action: #selector(MainSplitViewController.executeQuery(_:)),
                shortcut: .executeQuery,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Execute All Statements"),
                action: #selector(MainSplitViewController.executeAllStatements(_:)),
                shortcut: .executeAllStatements,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Execute Query Without Limit"),
                action: #selector(MainSplitViewController.executeQueryWithoutLimit(_:)),
                shortcut: .executeQueryWithoutLimit,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Cancel Query"),
                action: #selector(MainSplitViewController.cancelQuery(_:)),
                shortcut: .cancelQuery,
                keyboard: keyboard
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Explain Query"),
                action: #selector(MainSplitViewController.explainQuery(_:)),
                shortcut: .explainQuery,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Format Query"),
                action: #selector(MainSplitViewController.formatQuery(_:)),
                shortcut: .formatQuery,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Preview SQL"),
                action: #selector(MainSplitViewController.previewSQL(_:)),
                shortcut: .previewSQL,
                keyboard: keyboard
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Toggle Fold"),
                action: #selector(MainSplitViewController.toggleFold(_:)),
                shortcut: .toggleFold,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Fold All"),
                action: #selector(MainSplitViewController.foldAll(_:)),
                shortcut: .foldAll,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Unfold All"),
                action: #selector(MainSplitViewController.unfoldAll(_:)),
                shortcut: .unfoldAll,
                keyboard: keyboard
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Save as Favorite..."),
                action: #selector(MainSplitViewController.saveAsFavorite(_:)),
                shortcut: .saveAsFavorite,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Preview FK Reference"),
                action: #selector(MainSplitViewController.previewFKReference(_:)),
                shortcut: .previewFKReference,
                keyboard: keyboard
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "First Page"),
                action: #selector(MainSplitViewController.goToFirstPage(_:)),
                shortcut: .firstPage,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Previous Page"),
                action: #selector(MainSplitViewController.goToPreviousPage(_:)),
                shortcut: .previousPage,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Next Page"),
                action: #selector(MainSplitViewController.goToNextPage(_:)),
                shortcut: .nextPage,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Last Page"),
                action: #selector(MainSplitViewController.goToLastPage(_:)),
                shortcut: .lastPage,
                keyboard: keyboard
            ),
            MenuItemFactory.separator,
            MenuItemFactory.item(
                String(localized: "Explain with AI"),
                action: #selector(MainSplitViewController.explainQueryWithAI(_:)),
                shortcut: .aiExplainQuery,
                keyboard: keyboard
            ),
            MenuItemFactory.item(
                String(localized: "Optimize with AI"),
                action: #selector(MainSplitViewController.optimizeQueryWithAI(_:)),
                shortcut: .aiOptimizeQuery,
                keyboard: keyboard
            )
        ])
    }
}
