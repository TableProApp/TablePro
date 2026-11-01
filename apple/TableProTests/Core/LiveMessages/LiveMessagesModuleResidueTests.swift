import AppKit
import Foundation
@testable import TablePro
import Testing

// An off module leaves nothing behind (apple/AGENTS.md, Scope): no Live Messages… command anywhere in the menu bar.
@MainActor
struct LiveMessagesModuleResidueTests {
    private func liveItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item -> [NSMenuItem] in
            let own = item.action == #selector(MainSplitViewController.openLiveMessages(_:))
                || item.identifier == DatabaseMenuBuilder.liveMessagesIdentifier ? [item] : []
            return own + (item.submenu.map(liveItems(in:)) ?? [])
        }
    }

    @Test("Off: the menu bar has no Live Messages… command")
    func offLeavesNoMenuItem() {
        let bar = MainMenuBuilder.build(keyboard: KeyboardSettings(), modules: []).bar
        #expect(liveItems(in: bar).isEmpty)
    }

    @Test("On: Live Messages… sits in the Database menu, and turning the module off removes it")
    func togglesWithModule() throws {
        let built = MainMenuBuilder.build(keyboard: KeyboardSettings(), modules: [.liveMessages])
        let database = try #require(built.bar.items.first { $0.identifier == DatabaseMenuBuilder.identifier }?.submenu)
        #expect(liveItems(in: database).count == 1)

        MainMenuBuilder.applyModules([], keyboard: KeyboardSettings(), to: built.bar, windowsMenu: built.windowsMenu)
        #expect(liveItems(in: built.bar).isEmpty)

        MainMenuBuilder.applyModules([.liveMessages], keyboard: KeyboardSettings(), to: built.bar, windowsMenu: built.windowsMenu)
        #expect(liveItems(in: built.bar).count == 1)
    }

    @Test("The module is off by default")
    func offByDefault() {
        #expect(!AppModule.liveMessages.defaultEnabled)
    }
}
