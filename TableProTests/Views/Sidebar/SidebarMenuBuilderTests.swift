//
//  SidebarMenuBuilderTests.swift
//  TableProTests
//

import AppKit
import Testing

@testable import TablePro

@Suite("Sidebar menu builder")
@MainActor
struct SidebarMenuBuilderTests {
    private func build(_ sections: [DatabaseTreeMenuSection]) -> NSMenu {
        let menu = NSMenu()
        SidebarMenuBuilder.fill(
            menu,
            with: sections,
            target: NSObject(),
            action: #selector(NSObject.description as () -> String),
            keyboard: KeyboardSettings.default
        )
        return menu
    }

    /// The separator is the builder's to place now, so this is where the shape is guaranteed. The
    /// spec used to emit separators itself and a helper swept up the strays that made possible.
    @Test("A separator falls between groups and never opens, closes or doubles")
    func separatorsFallBetweenGroups() {
        let menu = build([
            DatabaseTreeMenuSection([.command("A", .createTable)]),
            DatabaseTreeMenuSection([]),
            DatabaseTreeMenuSection([.command("B", .createView)]),
        ])

        #expect(menu.items.map(\.isSeparatorItem) == [false, true, false])
    }

    @Test("An empty group contributes no separator")
    func emptyGroupsAreDropped() {
        let menu = build([
            DatabaseTreeMenuSection([]),
            DatabaseTreeMenuSection([.command("only", .createTable)]),
            DatabaseTreeMenuSection([]),
        ])

        #expect(menu.items.count == 1)
        #expect(!menu.items[0].isSeparatorItem)
    }

    @Test("A menu of nothing but empty groups builds nothing")
    func allEmptyBuildsNothing() {
        #expect(build([DatabaseTreeMenuSection([]), DatabaseTreeMenuSection([])]).items.isEmpty)
    }

    /// Resolved through `MenuItemFactory` from the same `KeyboardSettings` the menu bar reads, so a
    /// rebind moves both. Spelling a key equivalent here instead would be a second copy of the
    /// binding that nothing forces to agree with the first.
    @Test("A command shares the key equivalent its menu-bar twin resolves to")
    func shortcutsMatchTheMenuBar() {
        let keyboard = KeyboardSettings.default
        let ref = DatabaseTreeTableRef(
            database: "app",
            schema: "public",
            table: TableInfo(name: "orders", type: .table, rowCount: nil, schema: "public")
        )
        let menu = build([DatabaseTreeMenuSection([
            .command("Truncate", .truncateTables(targets: [ref], ref: ref))
        ])])

        let expected = keyboard.menuKeyEquivalent(for: .truncateTable)
        #expect(menu.items[0].keyEquivalent == (expected?.characters ?? ""))
        #expect(menu.items[0].keyEquivalentModifierMask == (expected?.modifiers ?? []))
    }

    /// A command the menu bar never bound shows no shortcut, rather than one invented here.
    @Test("A command with no menu-bar binding shows no shortcut")
    func unboundCommandsShowNothing() {
        let menu = build([DatabaseTreeMenuSection([.command("Copy Name", .copyText("orders"))])])

        #expect(menu.items[0].keyEquivalent.isEmpty)
    }

    /// The spec decides what exists rather than what is dimmed, which is the HIG's hide-don't-dim
    /// rule, so nothing here is left for a validator to answer for.
    @Test("Every built item is enabled and the menu does not autoenable")
    func itemsAreEnabledAndNotAutoenabled() {
        let menu = build([DatabaseTreeMenuSection([.command("A", .createTable)])])

        #expect(!menu.autoenablesItems)
        #expect(menu.items[0].isEnabled)
    }

    @Test("A submenu is built from its own groups")
    func submenusCarryTheirOwnGroups() {
        let menu = build([DatabaseTreeMenuSection([
            .submenu(title: "View Options", sections: [
                DatabaseTreeMenuSection([.command("Icons", .toggleObjectIcons)]),
                DatabaseTreeMenuSection([.command("Small", .setRowSize(.small))]),
            ])
        ])])

        let submenu = try? #require(menu.items[0].submenu)
        #expect(submenu?.items.map(\.isSeparatorItem) == [false, true, false])
    }

    /// One source, so the control in the filter row and the empty-area menu can never list
    /// different options or report a different state.
    @Test("The filter row's control and the empty-area menu show the same options")
    func viewOptionsHaveOneSource() {
        let fromSettings = SidebarViewOptionsMenu.currentSections()
        let settings = AppSettingsManager.shared.general
        let fromContext = SidebarViewOptionsMenu.sections(
            showObjectIcons: settings.showObjectIcons,
            showObjectComments: settings.showObjectComments,
            rowSize: settings.sidebarRowSize
        )

        #expect(fromSettings == fromContext)
    }
}
