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
        guard let submenu = item.submenu else { return [item] }
        return [item] + flattenItems(submenu)
    }
}

private final class FiringTarget: NSObject {
    var fired = 0
    @objc func fire(_ sender: Any?) { fired += 1 }
}

@MainActor
struct WindowMenuTabCommandsTests {
    private func windowItems(_ keyboard: KeyboardSettings = KeyboardSettings()) throws -> [NSMenuItem] {
        let menu = try #require(WindowMenuBuilder.build(keyboard: keyboard).submenu)
        return menu.items
    }

    private func item(for action: Selector, in items: [NSMenuItem]) -> NSMenuItem? {
        items.first { $0.action == action }
    }

    // Without these two actions AppKit inserts its own pair, which listed both titles twice in 0.75 and took Control-Tab.
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

    @Test("Pin Tab follows the editor-tab commands and ships unbound")
    func pinTabSitsWithTheEditorTabCommands() throws {
        let items = try windowItems()
        let selector = #selector(MainSplitViewController.togglePinnedEditorTab(_:))
        let pin = try #require(item(for: selector, in: items))
        let index = try #require(items.firstIndex(of: pin))

        #expect(pin.title == String(localized: "Pin Tab"))
        #expect(pin.keyEquivalent.isEmpty)
        #expect(items[index - 1].action == #selector(MainSplitViewController.switchToLeastRecentTab(_:)))
        #expect(KeyboardSettings.defaultShortcuts[.pinTab] == nil)
        #expect(ShortcutAction.pinTab.category == .navigation)
    }

    @Test("Pin Tab needs a connected strip with a tab to act on")
    func pinTabEnablement() {
        let selector = #selector(MainSplitViewController.togglePinnedEditorTab(_:))
        var context = MenuValidationContext()
        context.isConnected = true
        #expect(!MainSplitViewController.isEnabled(selector, context: context))

        context.canPinEditorTab = true
        #expect(MainSplitViewController.isEnabled(selector, context: context))

        context.isAgentMode = true
        #expect(!MainSplitViewController.isEnabled(selector, context: context))
    }

    @Test("Rename Tab follows Pin Tab and ships unbound")
    func renameTabSitsAfterPinTab() throws {
        let items = try windowItems()
        let rename = try #require(item(for: #selector(MainSplitViewController.renameEditorTab(_:)), in: items))
        let index = try #require(items.firstIndex(of: rename))

        #expect(rename.title == String(localized: "Rename Tab"))
        #expect(rename.keyEquivalent.isEmpty)
        #expect(items[index - 1].action == #selector(MainSplitViewController.togglePinnedEditorTab(_:)))
        #expect(KeyboardSettings.defaultShortcuts[.renameTab] == nil)
        #expect(ShortcutAction.renameTab.category == .navigation)
        #expect(ShortcutAction.renameTab.displayName == String(localized: "Rename Tab"))
    }

    @Test("Rename Tab dims with one tab, on a tab that cannot take a name, in Agent mode and while not connected")
    func renameTabEnablement() {
        let selector = #selector(MainSplitViewController.renameEditorTab(_:))
        var context = MenuValidationContext()
        context.isConnected = true
        context.editorTabCount = 2
        context.canRenameEditorTab = true
        #expect(MainSplitViewController.isEnabled(selector, context: context))

        var single = context
        single.editorTabCount = 1
        #expect(!MainSplitViewController.isEnabled(selector, context: single))

        var ineligible = context
        ineligible.canRenameEditorTab = false
        #expect(!MainSplitViewController.isEnabled(selector, context: ineligible))

        var agent = context
        agent.isAgentMode = true
        #expect(!MainSplitViewController.isEnabled(selector, context: agent))

        var offline = context
        offline.isConnected = false
        #expect(!MainSplitViewController.isEnabled(selector, context: offline))
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

    // Built from `CGEvent`, since Control-Shift-Tab reports U+0019 rather than a tab and a test must not choose the characters.
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

    // A disabled item still takes its chord, which in a text view would otherwise move focus to the next control.
    @Test("Control-Tab is dropped where the key window holds no tabs, and kept where it does")
    func controlTabYieldsWithoutTabs() throws {
        let menu = MainMenuBuilder.build(keyboard: KeyboardSettings()).bar
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

    // Control-Tab is AppKit's window-tab chord, so with no editor tab to switch to it switches the window's tabs.
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

// Validated on `isConnected` alone these stayed lit in Agent mode, where no strip is drawn, and with nothing to switch to.
struct TabNavigationMenuValidationTests {
    private func context(tabs: Int, agent: Bool = false, number: Int? = nil) -> MenuValidationContext {
        var context = MenuValidationContext()
        context.hasSelectedWorkspace = true
        context.isConnected = true
        context.isAgentMode = agent
        context.editorTabCount = tabs
        context.requestedTabNumber = number
        return context
    }

    private let stepping = [
        #selector(MainSplitViewController.selectNextEditorTab(_:)),
        #selector(MainSplitViewController.selectPreviousEditorTab(_:))
    ]
    private let numbered = #selector(MainSplitViewController.selectNumberedTab(_:))

    @Test("Stepping needs a second tab and a strip on screen")
    @MainActor
    func steppingNeedsTwoTabsInBrowse() {
        for selector in stepping {
            #expect(MainSplitViewController.isEnabled(selector, context: context(tabs: 2)))
            #expect(MainSplitViewController.isEnabled(selector, context: context(tabs: 1)) == false)
            #expect(MainSplitViewController.isEnabled(selector, context: context(tabs: 3, agent: true)) == false)
        }
    }

    @Test("Select Tab N needs an Nth tab and a strip on screen")
    @MainActor
    func numberedNeedsThatTab() {
        #expect(MainSplitViewController.isEnabled(numbered, context: context(tabs: 3, number: 3)))
        #expect(MainSplitViewController.isEnabled(numbered, context: context(tabs: 3, number: 4)) == false)
        #expect(MainSplitViewController.isEnabled(numbered, context: context(tabs: 3, agent: true, number: 1)) == false)
    }

    // One tab shows no strip, and Select Tab 1 would reselect the tab already in front.
    @Test("Select Tab 1 dims with a single tab")
    @MainActor
    func numberedDimsWithOneTab() throws {
        let menu = try #require(WindowMenuBuilder.build(keyboard: KeyboardSettings()).submenu)
        let selectFirst = try #require(menu.items.first { $0.action == numbered && $0.keyEquivalent == "1" })

        #expect(MainSplitViewController.isEnabled(numbered, context: context(tabs: 1, number: selectFirst.tag)) == false)
        #expect(MainSplitViewController.isEnabled(numbered, context: context(tabs: 2, number: selectFirst.tag)))
    }
}
