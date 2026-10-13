//
//  PrivilegeScopeOutlineThemeTests.swift
//  TableProTests
//
//  The privilege scope outline is a content table, so it takes the data grid's colors under a theme
//  and stays exactly AppKit's under a default one.
//

import AppKit
@testable import TablePro
import TableProPluginKit
import Testing

/// Each test adopts a pair on the shared `ThemeEngine` and restores it in a `defer`. The bodies are
/// synchronous and `@MainActor`, so nothing else on the main actor runs between the two.
@Suite("Privilege scope outline follows the theme", .serialized)
@MainActor
struct PrivilegeScopeOutlineThemeTests {
    private struct Mounted {
        let window: NSWindow
        let scrollView: NSScrollView
        let outline: PrivilegeScopeOutline
        let coordinator: PrivilegeScopeOutlineCoordinator
    }

    private func preservingEngine(_ body: () throws -> Void) rethrows {
        let engine = ThemeEngine.shared
        let restore = ThemeSelection(pair: engine.pair, effectiveAppearance: engine.effectiveAppearance)
        defer { engine.adopt(restore) }
        try body()
    }

    private func adopt(_ overrides: [ThemeSlot: String]) throws {
        var theme = BuiltInThemes.light
        if !overrides.isEmpty {
            theme.id = "user.test.privilege-outline"
            for (slot, hex) in overrides {
                theme.overrides[slot] = try ThemeColor(validating: hex)
            }
        }
        ThemeEngine.shared.adopt(ThemeSelection(
            pair: ThemePair(light: theme, dark: BuiltInThemes.dark),
            effectiveAppearance: .light
        ))
    }

    /// Never ordered front and never closed: `close()` on a test window over-releases it.
    private func mount() throws -> Mounted {
        let viewModel = UsersRolesViewModel(connectionId: UUID(), databaseType: .postgresql)
        viewModel.privilegeTree.showGrantedOnly(scopes: [.database("app"), .database("web")])
        let coordinator = PrivilegeScopeOutlineCoordinator(viewModel: viewModel)
        let scrollView = PrivilegeScopeOutlineView.makeScrollView(coordinator: coordinator)
        scrollView.frame = NSRect(x: 0, y: 0, width: 320, height: 160)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = scrollView
        let outline = try #require(scrollView.documentView as? PrivilegeScopeOutline)
        outline.reloadData()
        outline.layoutSubtreeIfNeeded()
        return Mounted(window: window, scrollView: scrollView, outline: outline, coordinator: coordinator)
    }

    private func hex(_ color: NSColor?) throws -> String {
        let color = try #require(color)
        var hex = ""
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            hex = HexColor.string(from: color)
        }
        return hex
    }

    @Test("Under the default theme the outline keeps AppKit's background, stripes and selection")
    func defaultThemeTouchesNothing() throws {
        try preservingEngine {
            try adopt([:])
            let mounted = try mount()
            let chrome = try #require(mounted.outline.themeChrome)

            let stock = NSOutlineView()
            stock.style = .fullWidth
            #expect(mounted.outline.backgroundColor == stock.backgroundColor)
            #expect(mounted.outline.usesAlternatingRowBackgroundColors)
            #expect(!mounted.scrollView.drawsBackground)
            #expect(!chrome.isBackgroundThemed)
            #expect(chrome.selectionColor(emphasized: true) == nil)
        }
    }

    @Test("Every row is a themed row view wired to the outline's chrome")
    func rowsUseTheThemedRowView() throws {
        try preservingEngine {
            try adopt([:])
            let mounted = try mount()
            #expect(mounted.outline.numberOfRows == 2)

            let row = try #require(mounted.outline.rowView(atRow: 1, makeIfNecessary: true) as? ThemeTableRowView)
            #expect(row.chrome === mounted.outline.themeChrome)
        }
    }

    @Test("Under a theme the outline takes the grid's background, stripes and selection, and gets its own back")
    func themeAppliesAndRestores() throws {
        try preservingEngine {
            try adopt([:])
            let mounted = try mount()
            let chrome = try #require(mounted.outline.themeChrome)
            let background = mounted.outline.backgroundColor

            try adopt([
                .gridBackground: "#FAFAFA",
                .gridAlternateRow: "#F0F0F0",
                .gridSelection: "#C8E1FF",
            ])
            #expect(try hex(mounted.outline.backgroundColor) == "#FAFAFA")
            #expect(!mounted.outline.usesAlternatingRowBackgroundColors)
            #expect(try hex(chrome.rowBackgroundColor(forRow: 0)) == "#FAFAFA")
            #expect(try hex(chrome.rowBackgroundColor(forRow: 1)) == "#F0F0F0")
            #expect(try hex(chrome.selectionColor(emphasized: true)) == "#C8E1FF")

            try adopt([:])
            #expect(mounted.outline.backgroundColor == background)
            #expect(mounted.outline.usesAlternatingRowBackgroundColors)
            #expect(!mounted.scrollView.drawsBackground)
            #expect(chrome.rowBackgroundColor(forRow: 1) == nil)
        }
    }
}
