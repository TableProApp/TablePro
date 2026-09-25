//
//  ConnectionActionsMenuDelegateTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

/// Stands in for the toolbar the delegate asks, so a test can move the context between two opens.
@MainActor
private final class ContextSource {
    var context: ToolbarContext

    init(_ context: ToolbarContext) {
        self.context = context
    }
}

/// What the Actions pull-down draws for a context. The resolver decides the entries and is pinned by
/// its own suite; this pins how they become menu items, which is where a target, a missing
/// `representedObject` or a lost chord would break the menu without the resolver noticing.
@MainActor
struct ConnectionActionsMenuDelegateTests {
    private static func context(
        tabKind: TabType? = .table,
        contentMode: ConnectionWorkspaceContentMode = .browse,
        isConnected: Bool = true
    ) -> ToolbarContext {
        ToolbarContext(
            tabKind: tabKind,
            resultsMode: .data,
            contentMode: contentMode,
            pane: isConnected ? .content : .unavailable(.notConnected),
            isConnected: isConnected,
            hasSelectedWorkspace: true,
            supportsImport: true,
            supportsServerDashboard: true,
            isAIEnabled: true
        )
    }

    private static func makeDelegate(for context: ToolbarContext) -> ConnectionActionsMenuDelegate {
        ConnectionActionsMenuDelegate(importFormats: ImportFormatMenuDelegate(), context: { context })
    }

    /// The submenus' delegates are held by the Actions delegate and `NSMenu.delegate` is weak, so a
    /// case that reads them keeps the Actions delegate alive for as long as it reads, the way the
    /// toolbar does for the life of the window.
    private static func withItems(
        for context: ToolbarContext,
        keyboard: KeyboardSettings = KeyboardSettings(),
        _ body: ([NSMenuItem]) throws -> Void
    ) rethrows {
        let delegate = makeDelegate(for: context)
        try withExtendedLifetime(delegate) {
            try body(delegate.items(for: context, keyboard: keyboard))
        }
    }

    /// With a target, a command is validated by that object instead of the responder chain, and the
    /// toolbar's own `validateMenuItem` answers true for every action it did not build. A submenu's
    /// own row is AppKit's to wire, and it targets the submenu.
    @Test("No command carries a target, so the window validates every one")
    func entriesCarryNoTarget() {
        for contentMode in ConnectionWorkspaceContentMode.allCases {
            Self.withItems(for: Self.context(contentMode: contentMode)) { items in
                for item in items where !item.isSeparatorItem {
                    if let submenu = item.submenu {
                        #expect(item.target === submenu, "\(item.title)")
                    } else {
                        #expect(item.target == nil, "\(item.title)")
                    }
                }
            }
        }
    }

    @Test("Sections are divided by separators, and nothing else is")
    func sectionsAreDividedBySeparators() {
        let context = Self.context()
        let sections = ConnectionActionsMenuResolver.sections(context)
        let items = Self.makeDelegate(for: context).items(for: context, keyboard: KeyboardSettings())

        #expect(items.filter(\.isSeparatorItem).count == sections.count - 1)
        #expect(items.count == sections.reduce(0) { $0 + $1.entries.count } + sections.count - 1)
        #expect(items.first?.isSeparatorItem == false)
        #expect(items.last?.isSeparatorItem == false)
    }

    /// The chord comes from the user's own binding, the way the menu bar's does, so a rebind in
    /// Settings reaches this menu on its next open.
    @Test("An entry with a shortcut shows the user's binding")
    func shortcutsFollowTheBinding() throws {
        var keyboard = KeyboardSettings()
        keyboard.setShortcut(.character("j", command: true, control: true), for: .addRow)
        let context = Self.context()
        let items = Self.makeDelegate(for: context).items(for: context, keyboard: keyboard)
        let addRow = try #require(items.first { $0.action == NSSelectorFromString("addRow:") })

        #expect(addRow.keyEquivalent == "j")
        #expect(addRow.keyEquivalentModifierMask == [.command, .control])
    }

    /// AppKit ignores a key equivalent on an item that owns a submenu, so the root carries none,
    /// and the leaves are filled when it opens.
    @Test("The import formats and the modes open submenus their delegates fill")
    func submenusHaveDelegates() throws {
        try Self.withItems(for: Self.context()) { items in
            let importRoot = try #require(items.first { $0.title == String(localized: "Import Data From") })
            let modeRoot = try #require(items.first { $0.title == String(localized: "Mode") })

            for root in [importRoot, modeRoot] {
                #expect(root.keyEquivalent.isEmpty)
                #expect(root.submenu?.delegate != nil)
            }
            #expect(importRoot.submenu?.delegate is ImportFormatMenuDelegate)
            #expect(modeRoot.submenu?.delegate is ContentModeMenuDelegate)
        }
    }

    /// The command ⇧⌘I runs is drawn as a leaf the responder chain validates, so the window dims it
    /// when there is nothing to import, and it shows the user's own chord for it. As a submenu's row
    /// it could show neither.
    @Test("Import Data… is a leaf that reaches the window and shows its binding")
    func importDataIsAPlainLeaf() throws {
        var keyboard = KeyboardSettings()
        keyboard.setShortcut(.character("u", command: true, control: true), for: .importData)
        try Self.withItems(for: Self.context(), keyboard: keyboard) { items in
            let leaf = try #require(items.first { $0.title == String(localized: "Import Data…") })

            #expect(leaf.submenu == nil)
            #expect(leaf.action == #selector(MainSplitViewController.importData(_:)))
            #expect(leaf.target == nil)
            #expect(leaf.keyEquivalent == "u")
            #expect(leaf.keyEquivalentModifierMask == [.command, .control])
        }
    }

    /// The format list's row cannot be dimmed through the responder chain, so an empty list says why
    /// it is empty rather than opening as a blank sliver.
    @Test("An import list with nothing to offer says so")
    func emptyImportListSaysSo() throws {
        let menu = NSMenu()
        menu.addItem(ImportFormatMenuDelegate.item(for: ImportFormatOption(id: "stale", name: "Stale")))

        ImportFormatMenuDelegate().menuNeedsUpdate(menu)

        let placeholder = try #require(menu.items.first)
        #expect(menu.items.count == 1)
        #expect(placeholder.title == String(localized: "None Available"))
        #expect(placeholder.action == nil)
        #expect(placeholder.isEnabled == false)
    }

    /// `setContentModeFromMenu(_:)` reads the mode out of `representedObject` and does nothing
    /// without it, and the window's validation reads the same value to tick the current mode.
    @Test("Each mode entry names its mode, for the action and for the checkmark")
    func modeEntriesNameTheirMode() {
        let menu = NSMenu()
        ContentModeMenuDelegate().menuNeedsUpdate(menu)

        #expect(menu.items.count == ConnectionWorkspaceContentMode.allCases.count)
        for (item, mode) in zip(menu.items, ConnectionWorkspaceContentMode.allCases) {
            #expect(item.title == mode.localizedTitle)
            #expect(item.representedObject as? String == mode.rawValue)
            #expect(item.action == #selector(MainSplitViewController.setContentModeFromMenu(_:)))
            #expect(item.target == nil)
        }
    }

    /// The parent row already says Import Data From, so the leaf is the format alone. Under that
    /// parent the sidebar's "From CSV…" would read twice.
    @Test("An import format entry names its format and reaches the window")
    func importFormatEntryNamesItsFormat() {
        let item = ImportFormatMenuDelegate.item(for: ImportFormatOption(id: "csv", name: "CSV"))

        #expect(item.title == "CSV\u{2026}")
        #expect(item.representedObject as? String == "csv")
        #expect(item.action == #selector(MainSplitViewController.importDataFormat(_:)))
        #expect(item.target == nil)
    }

    /// Filled on open from the context the toolbar is pointed at when it opens, so a menu opened
    /// once cannot go on describing a tab the window has left.
    @Test("The menu is rebuilt from the current context each time it opens")
    func menuFollowsTheContextOnEachOpen() {
        let source = ContextSource(Self.context(tabKind: .table))
        let delegate = ConnectionActionsMenuDelegate(
            importFormats: ImportFormatMenuDelegate(),
            context: { source.context }
        )
        let menu = NSMenu()

        delegate.menuNeedsUpdate(menu)
        #expect(menu.items.contains { $0.action == NSSelectorFromString("addRow:") })

        source.context = Self.context(tabKind: .query)
        delegate.menuNeedsUpdate(menu)
        #expect(!menu.items.contains { $0.action == NSSelectorFromString("addRow:") })
        #expect(menu.items.contains { $0.action == NSSelectorFromString("toggleResults:") })
    }
}
