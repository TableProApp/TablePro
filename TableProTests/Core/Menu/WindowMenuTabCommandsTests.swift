//
//  WindowMenuTabCommandsTests.swift
//  TableProTests
//

import AppKit
import Carbon.HIToolbox
@testable import TablePro
import Testing

private func flattenItems(_ menu: NSMenu) -> [NSMenuItem] {
    menu.items.flatMap { item -> [NSMenuItem] in
        guard let submenu = item.submenu, submenu !== NSApp.servicesMenu else { return [item] }
        return [item] + flattenItems(submenu)
    }
}

private final class FiringTarget: NSObject {
    var fired = 0
    @objc func fire(_ sender: Any?) { fired += 1 }
}

@Suite("Window menu tab commands")
@MainActor
struct WindowMenuTabCommandsTests {
    private func windowItems(_ keyboard: KeyboardSettings = KeyboardSettings()) throws -> [NSMenuItem] {
        let menu = try #require(WindowMenuBuilder.build(keyboard: keyboard).submenu)
        return menu.items
    }

    private func item(for action: Selector, in items: [NSMenuItem]) -> NSMenuItem? {
        items.first { $0.action == action }
    }

    /// AppKit inserts its own Show Previous Tab and Show Next Tab, on Control-Shift-Tab and
    /// Control-Tab, into a Window menu that does not hold these two actions. Measured in 0.75: the
    /// menu then listed both titles twice, and the inserted pair took Control-Tab first.
    @Test("The menu owns the window-tab commands under their own names")
    func ownsWindowTabCommands() throws {
        let items = try windowItems()
        let previous = try #require(item(for: #selector(NSWindow.selectPreviousTab(_:)), in: items))
        let next = try #require(item(for: #selector(NSWindow.selectNextTab(_:)), in: items))

        #expect(previous.title == String(localized: "Show Previous Window Tab"))
        #expect(next.title == String(localized: "Show Next Window Tab"))
        #expect(previous.keyEquivalent.isEmpty)
        #expect(next.keyEquivalent.isEmpty)
    }

    @Test("Control-Tab and Control-Shift-Tab each belong to one recent-tab command")
    func controlTabClaimedOnce() throws {
        let items = try windowItems()
        let forward = try #require(item(for: #selector(MainSplitViewController.switchToRecentTab(_:)), in: items))
        let backward = try #require(item(for: #selector(MainSplitViewController.switchToLeastRecentTab(_:)), in: items))

        #expect(forward.keyEquivalent == "\t")
        #expect(forward.keyEquivalentModifierMask == .control)
        #expect(backward.keyEquivalent == "\t")
        #expect(backward.keyEquivalentModifierMask == [.control, .shift])
        #expect(items.filter { $0.keyEquivalent == "\t" }.count == 2)
    }

    @Test("Show Previous Tab and Show Next Tab keep the strip-order shortcuts")
    func stripOrderCommandsUnchanged() throws {
        let items = try windowItems()
        let previous = try #require(item(for: #selector(MainSplitViewController.selectPreviousEditorTab(_:)), in: items))
        let next = try #require(item(for: #selector(MainSplitViewController.selectNextEditorTab(_:)), in: items))

        #expect(previous.keyEquivalent == "[")
        #expect(next.keyEquivalent == "]")
        #expect(previous.keyEquivalentModifierMask == [.command, .shift])
    }

    /// The chord a real keyboard produces, with the character AppKit derives: Control-Shift-Tab
    /// reports U+0019 rather than a tab. Built from `CGEvent` so the characters are the ones a user
    /// would type, not ones a test chose.
    private func typedTab(control: Bool, shift: Bool) throws -> NSEvent {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Tab), keyDown: true))
        var flags: CGEventFlags = []
        if control { flags.insert(.maskControl) }
        if shift { flags.insert(.maskShift) }
        event.flags = flags
        return try #require(NSEvent(cgEvent: event))
    }

    private func dispatches(_ shortcut: ShortcutAction, event: NSEvent) -> Bool {
        let target = FiringTarget()
        let menu = NSMenu()
        menu.addItem(MenuItemFactory.item(
            "Probe",
            action: #selector(FiringTarget.fire(_:)),
            shortcut: shortcut,
            keyboard: KeyboardSettings(),
            target: target
        ))
        return menu.performKeyEquivalent(with: event) && target.fired == 1
    }

    @Test("A typed Control-Tab and Control-Shift-Tab reach their menu items")
    func typedChordsDispatch() throws {
        #expect(dispatches(.switchToRecentTab, event: try typedTab(control: true, shift: false)))
        #expect(dispatches(.switchToLeastRecentTab, event: try typedTab(control: true, shift: true)))
        #expect(dispatches(.switchToRecentTab, event: try typedTab(control: true, shift: true)) == false)
    }

    /// A disabled item still takes its chord, and in a text view Control-Tab moves focus to the next
    /// control, so a window with no tabs of either kind has to lose the key equivalents outright.
    @Test("Control-Tab is dropped where the key window holds no tabs, and kept where it does")
    func controlTabYieldsWithoutTabs() throws {
        let menu = MainMenuBuilder.build(keyboard: KeyboardSettings())
        let recent = MenuItemFactory.identifier(for: .switchToRecentTab)
        let findItem = { flattenItems(menu).first { $0.identifier == recent } }

        MainMenuBuilder.syncKeyEquivalents(keyboard: KeyboardSettings(), actions: nil, keyWindowHasTabs: false, to: menu)
        #expect(findItem()?.keyEquivalent.isEmpty == true)

        MainMenuBuilder.syncKeyEquivalents(keyboard: KeyboardSettings(), actions: nil, keyWindowHasTabs: true, to: menu)
        #expect(findItem()?.keyEquivalent == "\t")
        #expect(findItem()?.keyEquivalentModifierMask == .control)
    }

    @Test("Window-tab switching can be given a shortcut in Settings")
    func windowTabCommandsAreRebindable() throws {
        var keyboard = KeyboardSettings()
        keyboard.setShortcut(.character("[", command: true, option: true, control: true), for: .showPreviousWindowTab)
        let previous = try #require(item(for: #selector(NSWindow.selectPreviousTab(_:)), in: try windowItems(keyboard)))

        #expect(previous.keyEquivalent == "[")
        #expect(previous.keyEquivalentModifierMask == [.command, .option, .control])
    }
}

@Suite("Recent tab switching menu validation")
struct RecentTabMenuValidationTests {
    private let selectors = [
        #selector(MainSplitViewController.switchToRecentTab(_:)),
        #selector(MainSplitViewController.switchToLeastRecentTab(_:))
    ]

    private func context(connected: Bool = true, agent: Bool = false, hasTab: Bool = true) -> MenuValidationContext {
        var context = MenuValidationContext()
        context.hasSelectedWorkspace = true
        context.isConnected = connected
        context.isAgentMode = agent
        context.hasRecentTabToSwitchTo = hasTab
        return context
    }

    @Test("Enabled when the window has another tab to switch to")
    @MainActor
    func enabledWithTwoTabs() {
        for selector in selectors {
            #expect(MainSplitViewController.isEnabled(selector, context: context()))
        }
    }

    @Test("Dimmed with one tab, in Agent mode, and while not connected")
    @MainActor
    func dimmedWithoutSomethingToSwitchTo() {
        for selector in selectors {
            #expect(MainSplitViewController.isEnabled(selector, context: context(hasTab: false)) == false)
            #expect(MainSplitViewController.isEnabled(selector, context: context(agent: true)) == false)
            #expect(MainSplitViewController.isEnabled(selector, context: context(connected: false)) == false)
        }
    }

    /// Control-Tab is AppKit's window-tab chord. A window in a tab group with nothing to switch to in
    /// its own strip still offers it, and the command switches the window's tabs instead.
    @Test("Enabled in a window tab group even with no editor tab to switch to")
    @MainActor
    func windowTabsKeepTheChord() {
        var fallback = context(connected: false, hasTab: false)
        fallback.hasOtherWindowTabs = true
        for selector in selectors {
            #expect(MainSplitViewController.isEnabled(selector, context: fallback))
        }
    }

    @Test("At most the connection on screen is frontmost, and only in the key window")
    @MainActor
    func frontmostRule() {
        let selected = UUID()

        #expect(MainSplitViewController.frontmostConnectionId(
            selectedConnectionId: selected, windowIsKey: true, showsTabs: { _ in true }
        ) == selected)
        #expect(MainSplitViewController.frontmostConnectionId(
            selectedConnectionId: selected, windowIsKey: false, showsTabs: { _ in true }
        ) == nil)
        #expect(MainSplitViewController.frontmostConnectionId(
            selectedConnectionId: selected, windowIsKey: true, showsTabs: { _ in false }
        ) == nil)
        #expect(MainSplitViewController.frontmostConnectionId(
            selectedConnectionId: nil, windowIsKey: true, showsTabs: { _ in true }
        ) == nil)
    }
}
