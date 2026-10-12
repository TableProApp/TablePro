//
//  MainMenuBuildPurityTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@MainActor
struct MainMenuBuildPurityTests {
    private struct ItemShape: Equatable {
        let title: String
        let action: Selector?
        let keyEquivalent: String
        let modifiers: NSEvent.ModifierFlags
        let identifier: String?
        let tag: Int
        let isHidden: Bool
        let isSeparator: Bool
        let children: [ItemShape]
    }

    private func shape(of menu: NSMenu) -> [ItemShape] {
        menu.items.map { item in
            ItemShape(
                title: item.title,
                action: item.action,
                keyEquivalent: item.keyEquivalent,
                modifiers: item.keyEquivalentModifierMask,
                identifier: item.identifier?.rawValue,
                tag: item.tag,
                isHidden: item.isHidden,
                isSeparator: item.isSeparatorItem,
                children: item.submenu.map(shape(of:)) ?? []
            )
        }
    }

    private func submenu(titled title: String, in bar: NSMenu) -> NSMenu? {
        bar.items.first { $0.title == title }?.submenu
    }

    @Test("Building twice yields the same structure and leaves NSApp's menus alone")
    func buildIsSideEffectFree() {
        let mainMenu = NSApp.mainMenu
        let servicesMenu = NSApp.servicesMenu
        let windowsMenu = NSApp.windowsMenu
        let helpMenu = NSApp.helpMenu

        let first = MainMenuBuilder.build(keyboard: KeyboardSettings())
        let second = MainMenuBuilder.build(keyboard: KeyboardSettings())

        #expect(first.bar !== second.bar)
        #expect(!shape(of: first.bar).isEmpty)
        #expect(shape(of: first.bar) == shape(of: second.bar))
        #expect(NSApp.mainMenu === mainMenu)
        #expect(NSApp.servicesMenu === servicesMenu)
        #expect(NSApp.windowsMenu === windowsMenu)
        #expect(NSApp.helpMenu === helpMenu)
    }

    @Test("The menus to register are the bar's own Services, Window and Help menus")
    func registeredMenusBelongToTheBar() throws {
        let built = MainMenuBuilder.build(keyboard: KeyboardSettings())
        let app = try #require(submenu(titled: "TablePro", in: built.bar))
        let services = try #require(app.items.first { $0.title == String(localized: "Services") }?.submenu)

        #expect(built.servicesMenu === services)
        #expect(built.windowsMenu === submenu(titled: String(localized: "Window"), in: built.bar))
        #expect(built.helpMenu === submenu(titled: String(localized: "Help"), in: built.bar))
    }

    @Test("The installed bar registers its own Window, Help and Services menus with NSApp")
    func installRegistersTheBarsMenus() throws {
        let bar = try #require(NSApp.mainMenu)
        let app = try #require(submenu(titled: "TablePro", in: bar))
        let services = try #require(app.items.first { $0.title == String(localized: "Services") }?.submenu)

        #expect(NSApp.servicesMenu === services)
        #expect(NSApp.windowsMenu === submenu(titled: String(localized: "Window"), in: bar))
        #expect(NSApp.helpMenu === submenu(titled: String(localized: "Help"), in: bar))
    }
}
