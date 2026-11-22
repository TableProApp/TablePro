import AppKit
import Foundation
@testable import TablePro
import TableProConnectionLibrary
import Testing

// An off module leaves nothing behind (apple/AGENTS.md, Scope). No URL, AppleScript or MCP request opens Compare & Sync,
// so the menu bar and the Welcome connection menu are every way in.
@MainActor
struct CompareSyncModuleResidueTests {
    private static let commands: Set<Selector> = [
        #selector(AppDelegate.compareAndSyncDatabases(_:)),
        #selector(CompareSyncWindowController.saveComparison(_:)),
        #selector(CompareSyncWindowController.runComparison(_:)),
        #selector(CompareSyncWindowController.swapEndpoints(_:)),
        #selector(CompareSyncWindowController.showOptions(_:)),
        #selector(CompareSyncWindowController.generateScript(_:)),
        #selector(CompareSyncWindowController.applyToTarget(_:)),
        #selector(CompareSyncWindowController.stopComparison(_:)),
    ]

    private func flatten(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item -> [NSMenuItem] in
            guard let submenu = item.submenu else { return [item] }
            return [item] + flatten(submenu)
        }
    }

    private func compareItems(in menu: NSMenu) -> [NSMenuItem] {
        flatten(menu).filter { item in
            if let action = item.action, Self.commands.contains(action) { return true }
            return item.identifier == DatabaseMenuBuilder.compareIdentifier
                || item.identifier == DatabaseMenuBuilder.compareSeparatorIdentifier
        }
    }

    private func databaseMenu(_ bar: NSMenu) throws -> NSMenu {
        try #require(bar.items.first { $0.identifier == DatabaseMenuBuilder.identifier }?.submenu)
    }

    private func modules(on: Bool, in suite: EphemeralDefaults) -> AppModuleSettings {
        let settings = AppModuleSettings(defaults: suite.defaults, notificationCenter: NotificationCenter())
        settings.setEnabled(on, for: .compareSync)
        return settings
    }

    private func welcomeTitles(compareSyncOn: Bool) -> [String] {
        let connection = DatabaseConnection(name: "Prod", type: .mysql)
        let context = WelcomeMenuSpecTests().context(
            rows: [.connection(connection.id, section: .connections)],
            connections: [connection],
            isCompareSyncEnabled: compareSyncOn
        )
        return WelcomeMenuSpec.sections(for: context).flatMap(\.items).compactMap { item in
            guard case .command(let entry) = item else { return nil }
            return entry.title
        }
    }

    private func runningSession() -> CompareSyncSession {
        let session = CompareSyncSession()
        session.activity = .comparing
        return session
    }

    // MARK: - Off

    @Test("Off: the menu bar has no Compare submenu or command, and the Database menu ends at Reconnect")
    func offLeavesNoMenu() throws {
        let bar = MainMenuBuilder.build(keyboard: KeyboardSettings(), modules: []).bar
        let leftovers = compareItems(in: bar).map(\.title)
        let last = try #require(try databaseMenu(bar).items.last)

        #expect(leftovers.isEmpty, "Compare items in the menu bar with the module off: \(leftovers)")
        #expect(!last.isSeparatorItem)
        #expect(last.action == #selector(MainSplitViewController.retryConnection))
    }

    @Test("Off: a connection in the Welcome window offers no Compare & Sync With…")
    func offLeavesNoWelcomeItem() {
        let titles = welcomeTitles(compareSyncOn: false)

        #expect(!titles.contains(String(localized: "Compare & Sync With…")))
        #expect(titles.contains(String(localized: "Duplicate")))
    }

    @Test("Settings > Keyboard lists the same rows on or off, and no Compare command takes a key")
    func keyboardIsUntouched() {
        let rows: (Set<AppModule>) -> [ShortcutAction] = { enabled in
            ShortcutCategory.allCases.flatMap { ShortcutAction.settingsRows(in: $0, enabledModules: enabled) }
        }
        let bar = MainMenuBuilder.build(keyboard: KeyboardSettings(), modules: [.compareSync]).bar
        let keyed = compareItems(in: bar).filter { !$0.keyEquivalent.isEmpty }.map(\.title)

        #expect(rows([]) == rows([.compareSync]))
        #expect(keyed.isEmpty, "Compare commands with a key equivalent: \(keyed)")
    }

    // A statement already sent can still be writing, so quitting asks until the run itself ends, as after closing the window.
    @Test("A run that turning the module off cancelled stays in the quit check until it ends")
    func cancelledRunStaysInTheQuitCheck() {
        let registry = CompareSyncRunRegistry()
        let session = runningSession()
        registry.track(session, windowId: UUID()) {}

        registry.endAll()
        let draining = registry.runningWork().map { $0.id }
        session.activity = .idle

        #expect(draining == [session.workId])
        #expect(registry.runningWork().isEmpty)
    }

    @Test("Off: opening Compare & Sync opens nothing and never reads the license")
    func offOpensNothing() {
        var licenseReads = 0
        let decision = CompareSyncLauncher.launch(moduleEnabled: false) {
            licenseReads += 1
            return true
        }

        #expect(decision == .moduleOff)
        #expect(licenseReads == 0)
    }

    // The host's own module state, which no test turns on, as a new install has it.
    @Test("Off: the launcher the menus call opens no window in the host")
    func offHostOpensNoWindow() throws {
        try #require(!AppModuleSettings.shared.isEnabled(.compareSync))
        CompareSyncLauncher.open(prefillSource: UUID())

        #expect(!NSApp.windows.contains { $0.identifier?.rawValue == WindowIdentifier.compareSync })
    }

    // MARK: - On

    @Test("On: the Compare submenu closes the Database menu behind a separator, with its eight commands")
    func onAddsTheSubmenu() throws {
        let bar = MainMenuBuilder.build(keyboard: KeyboardSettings(), modules: [.compareSync]).bar
        let items = try databaseMenu(bar).items
        let last = try #require(items.last)
        let commands = (last.submenu?.items ?? []).filter { !$0.isSeparatorItem }
        let actions = Set(commands.compactMap { $0.action })
        let targeted = commands.filter { $0.target != nil }.map(\.title)

        #expect(last.identifier == DatabaseMenuBuilder.compareIdentifier)
        #expect(items[items.count - 2].isSeparatorItem)
        #expect(items[items.count - 2].identifier == DatabaseMenuBuilder.compareSeparatorIdentifier)
        #expect(commands.count == 8)
        #expect(actions == Self.commands)
        #expect(targeted.isEmpty)
    }

    @Test("On: a connection in the Welcome window offers Compare & Sync With… after Duplicate")
    func onAddsTheWelcomeItem() throws {
        let titles = welcomeTitles(compareSyncOn: true)
        let duplicate = try #require(titles.firstIndex(of: String(localized: "Duplicate")))

        #expect(titles[duplicate + 1] == String(localized: "Compare & Sync With…"))
    }

    @Test("On: without a license opening asks for one, as before; with one it opens")
    func onKeepsTheLicenseGate() {
        #expect(CompareSyncLauncher.launch(moduleEnabled: true) { false } == .needsLicense)
        #expect(CompareSyncLauncher.launch(moduleEnabled: true) { true } == .open)
    }

    // MARK: - Switching

    @Test("Switching the module adds and removes the Compare submenu in the installed bar at once")
    func switchingEditsTheInstalledBar() throws {
        let built = MainMenuBuilder.build(keyboard: KeyboardSettings(), modules: [])
        let offTitles = try databaseMenu(built.bar).items.map(\.title)

        MainMenuBuilder.applyModules([.compareSync], keyboard: KeyboardSettings(), to: built.bar, windowsMenu: built.windowsMenu)
        MainMenuBuilder.applyModules([.compareSync], keyboard: KeyboardSettings(), to: built.bar, windowsMenu: built.windowsMenu)
        let onTitles = try databaseMenu(built.bar).items.map(\.title)
        let onBuilt = MainMenuBuilder.build(keyboard: KeyboardSettings(), modules: [.compareSync]).bar
        let onBuiltTitles = try databaseMenu(onBuilt).items.map(\.title)
        let compareCount = try databaseMenu(built.bar).items.filter { $0.identifier == DatabaseMenuBuilder.compareIdentifier }.count

        #expect(onTitles == onBuiltTitles)
        #expect(compareCount == 1)

        MainMenuBuilder.applyModules([], keyboard: KeyboardSettings(), to: built.bar, windowsMenu: built.windowsMenu)
        let switchedOffTitles = try databaseMenu(built.bar).items.map(\.title)
        #expect(switchedOffTitles == offTitles)
        #expect(compareItems(in: built.bar).isEmpty)
    }

    // Through the Extensions checkbox's own path; it edits the host's menu bar, so the case ends with the module off.
    @Test("Turning the module off stops every comparison and closes every Compare & Sync window")
    func turningOffEndsEveryRun() throws {
        let suite = try EphemeralDefaults()
        let settings = modules(on: false, in: suite)
        let running = runningSession()
        let progress = Progress(totalUnitCount: 1)
        running.progress = progress
        let idle = CompareSyncSession()
        var closed: [String] = []
        CompareSyncRunRegistry.shared.track(running, windowId: UUID()) { closed.append("running") }
        CompareSyncRunRegistry.shared.track(idle, windowId: UUID()) { closed.append("idle") }

        AppModuleActivation.setEnabled(true, for: .compareSync, settings: settings)
        #expect(closed.isEmpty)
        AppModuleActivation.setEnabled(false, for: .compareSync, settings: settings)

        #expect(progress.isCancelled)
        #expect(closed.sorted() == ["idle", "running"])
    }
}
