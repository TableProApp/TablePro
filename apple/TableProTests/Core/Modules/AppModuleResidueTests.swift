import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

// An off module leaves nothing behind (apple/AGENTS.md, Scope). With it off no path opens a debug tab, so none can
// reach an MCP snapshot, AppleScript or recent tabs; the debug tab's own tests pin that one left open is excluded.
@MainActor
struct AppModuleResidueTests {
    private static let debugActions: [ShortcutAction] = [
        .debugContinue, .debugStepOver, .debugStepInto, .debugStepOut, .toggleBreakpoint,
    ]

    private static let routine = DatabaseTreeRoutineRef(
        database: "app",
        schema: "public",
        routine: RoutineInfo(name: "order_total", kind: .function, schema: "public", language: "plpgsql")
    )

    private static let target = PluginDebugTarget(
        identity: "16431",
        name: "order_total",
        schema: "public",
        kindDisplayName: "Function"
    )

    private func modules(on: Bool, in suite: EphemeralDefaults) -> AppModuleSettings {
        let settings = AppModuleSettings(defaults: suite.defaults, notificationCenter: NotificationCenter())
        settings.setEnabled(on, for: .routineDebugger)
        return settings
    }

    private func flatten(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item -> [NSMenuItem] in
            guard let submenu = item.submenu else { return [item] }
            return [item] + flatten(submenu)
        }
    }

    private func debugItems(in bar: NSMenu) -> [NSMenuItem] {
        let identifiers = Set(Self.debugActions.map { MenuItemFactory.identifier(for: $0) })
        return flatten(bar).filter { item in
            if let action = item.action, MainSplitViewController.routineDebugSelectors.contains(action) { return true }
            if let identifier = item.identifier, identifiers.contains(identifier) { return true }
            return item.identifier == DebugMenuBuilder.identifier || item.title == DebugMenuBuilder.title
        }
    }

    private func routineMenu(canDebug: Bool) -> [DatabaseTreeMenuSection] {
        var context = DatabaseTreeMenuSpecTests().context(clicked: .routine(Self.routine))
        context.canDebugRoutine = canDebug
        return DatabaseTreeMenuSpec.sections(for: context)
    }

    private func titles(_ sections: [DatabaseTreeMenuSection]) -> [String] {
        sections.flatMap { $0.items }.compactMap { item in
            guard case .command(let entry) = item else { return nil }
            return entry.title
        }
    }

    private func keyboardRows(_ enabled: Set<AppModule>) -> [ShortcutAction] {
        ShortcutCategory.allCases.flatMap { ShortcutAction.settingsRows(in: $0, enabledModules: enabled) }
    }

    // MARK: - Off

    @Test("Off: the built menu bar has no Debug menu, no debug command and no debug key equivalent")
    func offLeavesNoMenu() throws {
        let suite = try EphemeralDefaults()
        let settings = modules(on: false, in: suite)
        let bar = MainMenuBuilder.build(keyboard: KeyboardSettings(), modules: settings.enabledModules).bar

        let leftovers = debugItems(in: bar).map { $0.title }
        #expect(leftovers.isEmpty, "Debug items in the menu bar with the module off: \(leftovers)")

        let debugKeys = Set(Self.debugActions.compactMap { KeyboardSettings().menuKeyEquivalent(for: $0) }
            .map { "\($0.modifiers.rawValue)-\($0.characters)" })
        let claimed = flatten(bar)
            .filter { !$0.keyEquivalent.isEmpty }
            .map { "\($0.keyEquivalentModifierMask.rawValue)-\($0.keyEquivalent)" }
            .filter { debugKeys.contains($0) }
        #expect(claimed.isEmpty, "A debug default still reaches the menu bar: \(claimed)")
    }

    @Test("Off: a routine row offers no Debug… and the debugger is never asked")
    func offLeavesNoSidebarItem() throws {
        let suite = try EphemeralDefaults()
        let settings = modules(on: false, in: suite)
        var asked = 0
        let canDebug = DatabaseTreeMenuContext.canDebugRoutine(.routine(Self.routine), modules: settings) { _ in
            asked += 1
            return Self.target
        }
        let sections = routineMenu(canDebug: canDebug)
        let issued = DatabaseTreeMenuSpecTests().commands(sections)

        #expect(!canDebug)
        #expect(asked == 0)
        #expect(!issued.contains(.debugRoutine(Self.routine)))
        #expect(!titles(sections).contains(String(localized: "Debug…")))
    }

    @Test("Off: Settings > Keyboard lists no debug row and no Debug section")
    func offLeavesNoKeyboardRows() throws {
        let suite = try EphemeralDefaults()
        let settings = modules(on: false, in: suite)
        let rows = keyboardRows(settings.enabledModules)

        for action in Self.debugActions {
            #expect(!rows.contains(action), "\(action.rawValue)")
        }
        #expect(ShortcutAction.settingsRows(in: .debug, enabledModules: settings.enabledModules).isEmpty)
    }

    @Test("Off: recording a debug default for another command names no hidden debug command")
    func offDebugDefaultsClaimNothing() throws {
        let suite = try EphemeralDefaults()
        let settings = modules(on: false, in: suite)
        let keyboard = KeyboardSettings()

        for action in Self.debugActions {
            guard let key = KeyboardSettings.defaultShortcuts[action] else { continue }
            #expect(
                keyboard.findConflict(for: key, excluding: .refresh, enabledModules: settings.enabledModules) == nil,
                "\(key.displayString) is reported against \(action.rawValue)"
            )
        }
    }

    // Read from the host's own defaults, which no test turns the module on in.
    @Test("Off: a debug binding the user reassigned earlier stands no other command down")
    func offDebugOverrideClaimsNothing() throws {
        try #require(!AppModule.storedEnabledModules().contains(.routineDebugger))
        let refresh = try #require(KeyboardSettings.defaultShortcuts[.refresh])
        let keyboard = KeyboardSettings(shortcuts: [ShortcutAction.debugStepOver.rawValue: refresh])

        #expect(keyboard.shortcut(for: .refresh) == refresh)
    }

    // The coordinator reads the host's own module state, which no test turns on.
    @Test("Off: no path opens a debug tab or a debug session")
    func offOpensNoDebugTab() throws {
        try #require(!AppModuleSettings.shared.isEnabled(.routineDebugger))
        let fixture = CoordinatorFixture()
        let coordinator = fixture.coordinator

        #expect(coordinator.routineDebugTarget(for: Self.routine.routine) == nil)
        #expect(!coordinator.canChooseRoutineToDebug())
        coordinator.debugRoutine(Self.routine.routine)
        coordinator.chooseRoutineToDebug()

        #expect(fixture.tabManager.tabs.isEmpty)
        #expect(coordinator.frontRoutineDebugController == nil)
        #expect(!RoutineDebugSessions.shared.hasActiveSessions)
    }

    // MARK: - On

    @Test("On: the Debug menu sits after Query and before Window")
    func onAddsTheMenu() throws {
        let suite = try EphemeralDefaults()
        let settings = modules(on: true, in: suite)
        let titles = MainMenuBuilder.build(keyboard: KeyboardSettings(), modules: settings.enabledModules).bar
            .items.map { $0.title }

        let query = try #require(titles.firstIndex(of: String(localized: "Query")))
        let debug = try #require(titles.firstIndex(of: DebugMenuBuilder.title))
        let window = try #require(titles.firstIndex(of: String(localized: "Window")))
        #expect(debug == query + 1)
        #expect(window == debug + 1)
    }

    @Test("On: a routine the driver can debug offers Debug…")
    func onAddsTheSidebarItem() throws {
        let suite = try EphemeralDefaults()
        let settings = modules(on: true, in: suite)
        let canDebug = DatabaseTreeMenuContext.canDebugRoutine(.routine(Self.routine), modules: settings) { _ in
            Self.target
        }
        let sections = routineMenu(canDebug: canDebug)

        #expect(canDebug)
        #expect(DatabaseTreeMenuSpecTests().commands(sections).contains(.debugRoutine(Self.routine)))
        #expect(titles(sections).contains(String(localized: "Debug…")))
    }

    @Test("On: Settings > Keyboard lists the debug rows under Debug")
    func onAddsKeyboardRows() throws {
        let suite = try EphemeralDefaults()
        let settings = modules(on: true, in: suite)

        #expect(ShortcutAction.settingsRows(in: .debug, enabledModules: settings.enabledModules) == Self.debugActions)
        let rows = keyboardRows(settings.enabledModules)
        for action in Self.debugActions {
            #expect(rows.contains(action), "\(action.rawValue)")
        }
    }

    @Test("On: a debug default is reported against its command when recorded for another")
    func onDebugDefaultsAreClaimed() throws {
        let suite = try EphemeralDefaults()
        let settings = modules(on: true, in: suite)
        let stepOver = try #require(KeyboardSettings.defaultShortcuts[.debugStepOver])

        #expect(
            KeyboardSettings().findConflict(for: stepOver, excluding: .refresh, enabledModules: settings.enabledModules)
                == .debugStepOver
        )
    }

    // MARK: - Switching

    @Test("Switching the module adds and removes the Debug menu in the installed bar at once")
    func switchingEditsTheInstalledBar() throws {
        let built = MainMenuBuilder.build(keyboard: KeyboardSettings(), modules: [])
        let offTitles = built.bar.items.map { $0.title }

        MainMenuBuilder.applyModules([.routineDebugger], keyboard: KeyboardSettings(), to: built.bar, windowsMenu: built.windowsMenu)
        MainMenuBuilder.applyModules([.routineDebugger], keyboard: KeyboardSettings(), to: built.bar, windowsMenu: built.windowsMenu)
        let onTitles = built.bar.items.map { $0.title }
        let onBuilt = MainMenuBuilder.build(keyboard: KeyboardSettings(), modules: [.routineDebugger]).bar.items.map { $0.title }
        #expect(onTitles == onBuilt)
        #expect(built.bar.items.filter { $0.identifier == DebugMenuBuilder.identifier }.count == 1)

        MainMenuBuilder.applyModules([], keyboard: KeyboardSettings(), to: built.bar, windowsMenu: built.windowsMenu)
        #expect(built.bar.items.map { $0.title } == offTitles)
        #expect(debugItems(in: built.bar).isEmpty)
    }
}
