//
//  EditDataMenuGroupTests.swift
//  TableProTests
//

import AppKit
import Carbon.HIToolbox
@testable import TablePro
import Testing

private final class FiringTarget: NSObject {
    var fired = 0
    @objc func fire(_ sender: Any?) { fired += 1 }
}

@MainActor
struct EditDataMenuGroupTests {
    private func editMenu() throws -> NSMenu {
        try #require(EditMenuBuilder.build(keyboard: KeyboardSettings()).submenu)
    }

    private func flatten(_ items: [NSMenuItem]) -> [NSMenuItem] {
        items.flatMap { [$0] + flatten($0.submenu?.items ?? []) }
    }

    private func isGroupRoot(_ item: NSMenuItem) -> Bool {
        item.identifier == EditDataMenuGroup.separatorIdentifier || item.identifier == EditDataMenuGroup.submenuIdentifier
    }

    private func group(in menu: NSMenu) -> [NSMenuItem] {
        flatten(menu.items.filter(isGroupRoot))
    }

    private func headerRowItem(in menu: NSMenu) throws -> NSMenuItem {
        let identifier = MenuItemFactory.identifier(for: .toggleHeaderRow)
        return try #require(group(in: menu).first { $0.identifier == identifier })
    }

    private func commandShiftH() throws -> NSEvent {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_H), keyDown: true))
        event.flags = [.maskCommand, .maskShift]
        return try #require(NSEvent(cgEvent: event))
    }

    @Test("Edit > Data and the separator above it are built hidden, down to every leaf")
    func builtHidden() throws {
        let menu = try editMenu()
        let roots = menu.items.filter(isGroupRoot)
        #expect(roots.count == 2)
        #expect(roots.last?.title == String(localized: "Data"))
        #expect(group(in: menu).count > 20)
        #expect(group(in: menu).allSatisfy { $0.isHidden })
    }

    @Test("Showing and hiding the group leaves every other Edit item visible")
    func togglesOnlyTheGroup() throws {
        let menu = try editMenu()
        let others = flatten(menu.items.filter { !isGroupRoot($0) })
        #expect(!others.isEmpty)

        EditDataMenuGroup.setShown(true, in: menu)
        #expect(group(in: menu).allSatisfy { !$0.isHidden })
        #expect(others.allSatisfy { !$0.isHidden })

        EditDataMenuGroup.setShown(false, in: menu)
        #expect(group(in: menu).allSatisfy { $0.isHidden })
        #expect(others.allSatisfy { !$0.isHidden })
    }

    @Test("Only a data file window's controller shows the group")
    func onlyADataFileReceiverShowsTheGroup() {
        #expect(EditDataMenuGroup.isShown(forReceiver: DataFileSplitViewController(document: DataFileDocument())))
        #expect(!EditDataMenuGroup.isShown(forReceiver: nil))
        #expect(!EditDataMenuGroup.isShown(forReceiver: NSObject()))
    }

    @Test("A hidden group's shortcut does not match and a shown one does")
    func hiddenShortcutDoesNotMatch() throws {
        let menu = try editMenu()
        menu.delegate = nil
        let target = FiringTarget()
        let item = try headerRowItem(in: menu)
        item.target = target
        item.action = #selector(FiringTarget.fire(_:))

        #expect(!menu.performKeyEquivalent(with: try commandShiftH()))
        #expect(target.fired == 0)

        EditDataMenuGroup.setShown(true, in: menu)
        #expect(menu.performKeyEquivalent(with: try commandShiftH()))
        #expect(target.fired == 1)
    }

    /// The test host has no data file window, so the delegate must hide a group left shown, and it
    /// has to do so before AppKit matches the chord.
    @Test("The Edit menu's delegate updates the group before a shortcut is matched")
    func delegateRunsBeforeKeyEquivalentMatching() throws {
        let menu = try editMenu()
        #expect(menu.delegate is EditMenuDelegate)
        let target = FiringTarget()
        let item = try headerRowItem(in: menu)
        item.target = target
        item.action = #selector(FiringTarget.fire(_:))
        EditDataMenuGroup.setShown(true, in: menu)

        #expect(!menu.performKeyEquivalent(with: try commandShiftH()))
        #expect(target.fired == 0)
        #expect(group(in: menu).allSatisfy { $0.isHidden })
    }
}
