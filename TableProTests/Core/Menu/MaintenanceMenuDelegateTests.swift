//
//  MaintenanceMenuDelegateTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@Suite("Maintenance submenu population")
@MainActor
struct MaintenanceMenuDelegateTests {
    private func keyDownEvent() -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "k",
            charactersIgnoringModifiers: "k",
            isARepeat: false,
            keyCode: 40
        )
    }

    @Test("Key equivalent search never rebuilds the submenu")
    func keyEquivalentSearchDoesNotRebuild() throws {
        let delegate = MaintenanceMenuDelegate()
        let menu = NSMenu()
        menu.delegate = delegate
        let placeholder = NSMenuItem(title: "Placeholder", action: nil, keyEquivalent: "")
        menu.addItem(placeholder)

        let event = try #require(keyDownEvent())
        var target: AnyObject?
        var action: Selector?
        let handled = delegate.menuHasKeyEquivalent(menu, for: event, target: &target, action: &action)

        #expect(handled == false)
        #expect(menu.items == [placeholder])
        #expect(target === nil)
        #expect(action == nil)
    }

    @Test("Opening the submenu with no connected window shows the disabled empty state")
    func emptyStateWhenNoOperations() {
        let delegate = MaintenanceMenuDelegate()
        let menu = NSMenu()

        delegate.menuNeedsUpdate(menu)

        #expect(menu.items.count == 1)
        #expect(menu.items.first?.isEnabled == false)
    }
}

@Suite("New tab responder chain")
@MainActor
struct NewWindowForTabResponderTests {
    @Test("AppDelegate does not claim newWindowForTab, so AppKit disables it off editor windows")
    func appDelegateDoesNotClaimNewWindowForTab() {
        #expect(AppDelegate.instancesRespond(to: #selector(NSWindow.newWindowForTab(_:))) == false)
    }
}
