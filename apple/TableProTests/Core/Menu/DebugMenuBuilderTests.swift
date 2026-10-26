import AppKit
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct DebugMenuBuilderTests {
    private static let defaultedActions: [ShortcutAction] = [.debugContinue, .debugStepOver, .debugStepInto, .debugStepOut]

    private func bar(_ keyboard: KeyboardSettings = KeyboardSettings()) -> NSMenu {
        MainMenuBuilder.build(keyboard: keyboard, modules: [.routineDebugger]).bar
    }

    private func debugMenu(_ keyboard: KeyboardSettings = KeyboardSettings()) throws -> NSMenu {
        try #require(bar(keyboard).items.first { $0.identifier == DebugMenuBuilder.identifier }?.submenu)
    }

    private func flatten(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item -> [NSMenuItem] in
            guard let submenu = item.submenu else { return [item] }
            return [item] + flatten(submenu)
        }
    }

    private func functionKey(_ scalar: Int) -> String {
        Unicode.Scalar(UInt32(scalar)).map { String(Character($0)) } ?? ""
    }

    @Test("The Debug menu holds the debugger's commands in order")
    func commandOrder() throws {
        let menu = try debugMenu()
        let actions = menu.items.map { $0.isSeparatorItem ? nil : $0.action }

        #expect(actions == [
            #selector(MainSplitViewController.chooseRoutineToDebug(_:)),
            nil,
            #selector(MainSplitViewController.debugContinue(_:)),
            #selector(MainSplitViewController.debugStepOver(_:)),
            #selector(MainSplitViewController.debugStepInto(_:)),
            #selector(MainSplitViewController.debugStepOut(_:)),
            #selector(MainSplitViewController.debugStop(_:)),
            nil,
            #selector(MainSplitViewController.toggleBreakpoint(_:)),
            #selector(MainSplitViewController.removeAllBreakpoints(_:)),
        ])
        #expect(menu.items.first?.title == String(localized: "Debug Routine…"))
    }

    @Test("Continue, Step Over, Step Into and Step Out carry Xcode's keys and nothing else ships bound")
    func defaultKeys() throws {
        let items = try debugMenu().items.filter { !$0.isSeparatorItem }
        let keys = Dictionary(uniqueKeysWithValues: items.compactMap { item in
            item.action.map { ($0, (item.keyEquivalent, item.keyEquivalentModifierMask)) }
        })

        let continueKey = keys[#selector(MainSplitViewController.debugContinue(_:))]
        let commandControl: NSEvent.ModifierFlags = [.command, .control]
        let bare: NSEvent.ModifierFlags = []
        #expect(continueKey?.0 == "y")
        #expect(continueKey?.1 == commandControl)
        #expect(keys[#selector(MainSplitViewController.debugStepOver(_:))]?.0 == functionKey(NSF6FunctionKey))
        #expect(keys[#selector(MainSplitViewController.debugStepInto(_:))]?.0 == functionKey(NSF7FunctionKey))
        #expect(keys[#selector(MainSplitViewController.debugStepOut(_:))]?.0 == functionKey(NSF8FunctionKey))
        #expect(keys[#selector(MainSplitViewController.debugStepOver(_:))]?.1 == bare)

        let unbound: [Selector] = [
            #selector(MainSplitViewController.chooseRoutineToDebug(_:)),
            #selector(MainSplitViewController.debugStop(_:)),
            #selector(MainSplitViewController.toggleBreakpoint(_:)),
            #selector(MainSplitViewController.removeAllBreakpoints(_:)),
        ]
        for selector in unbound {
            #expect(keys[selector]?.0.isEmpty == true, "\(NSStringFromSelector(selector))")
        }
        #expect(KeyboardSettings.defaultShortcuts[.toggleBreakpoint] == nil)
    }

    @Test("Each debug default can be recorded again in Settings > Keyboard and is reserved by nothing")
    func defaultsAreRecordable() throws {
        for action in Self.defaultedActions {
            let key = try #require(KeyboardSettings.defaultShortcuts[action])
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: key.modifierFlags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: key.menuKeyEquivalent ?? "",
                charactersIgnoringModifiers: key.menuKeyEquivalent ?? "",
                isARepeat: false,
                keyCode: key.keyCode
            ))

            #expect(BoundKey(from: event) == key, "\(action.rawValue)")
            #expect(key.hasModifier || key.isFunctionKey, "\(action.rawValue)")
            #expect(ShortcutAction.reservedConflict(for: key, context: action.context) == nil, "\(action.rawValue)")
            #expect(KeyboardSettings().sanitized().shortcut(for: action) == key, "\(action.rawValue)")
        }
    }

    @Test("A rebound debug command reaches its menu item")
    func reboundKeyApplies() throws {
        let f10 = BoundKey.special(.f10)
        let menu = try debugMenu(KeyboardSettings(shortcuts: [ShortcutAction.debugStepOver.rawValue: f10]))
        let stepOver = try #require(menu.items.first { $0.action == #selector(MainSplitViewController.debugStepOver(_:)) })

        #expect(stepOver.keyEquivalent == functionKey(NSF10FunctionKey))
        #expect(stepOver.identifier == MenuItemFactory.identifier(for: .debugStepOver))
    }

    @Test("With the module on, no two items share a title or a key equivalent, and each leaf is a nil-target command")
    func moduleOnBarStaysConsistent() {
        let items = flatten(bar())
        let leaves = items.filter { !$0.isSeparatorItem && $0.submenu == nil }

        let titles = leaves.map { $0.title }
        let duplicateTitles = Dictionary(grouping: titles, by: { $0 }).filter { $0.value.count > 1 }.keys
        #expect(duplicateTitles.isEmpty, "\(duplicateTitles)")

        let combos = items.filter { !$0.keyEquivalent.isEmpty }
            .map { "\($0.keyEquivalentModifierMask.rawValue)-\($0.keyEquivalent)" }
        let duplicateCombos = Dictionary(grouping: combos, by: { $0 }).filter { $0.value.count > 1 }.keys
        #expect(duplicateCombos.isEmpty, "\(duplicateCombos)")

        let debugLeaves = leaves.filter { $0.action.map(MainSplitViewController.routineDebugSelectors.contains) ?? false }
        #expect(debugLeaves.count == MainSplitViewController.routineDebugSelectors.count)
        for item in debugLeaves {
            #expect(item.target == nil, "\(item.title)")
        }
    }

    @Test("Every Debug command reaches the window and dims with no debug tab in front")
    func everyDebugCommandIsDecided() throws {
        let selectors = try debugMenu().items.compactMap { $0.action }

        #expect(Set(selectors) == MainSplitViewController.routineDebugSelectors)
        for selector in selectors {
            let name = NSStringFromSelector(selector)
            #expect(MainSplitViewController.instancesRespond(to: selector), "\(name)")
            var connected = MenuValidationContext()
            connected.isConnected = true
            #expect(MainSplitViewController.resolvedEnablement(selector, context: connected) == false, "\(name)")
        }
    }

    @Test("Each Debug command follows the debug tab in front, and Agent mode dims them all")
    func debugCommandsFollowTheSession() {
        var context = MenuValidationContext()
        context.isConnected = true
        context.routineDebug = RoutineDebugMenuState(
            canChooseRoutine: true,
            performableCommands: [.stepOver, .stepInto],
            canStop: true,
            canToggleBreakpoint: true,
            canRemoveAllBreakpoints: false
        )
        let expected: [(Selector, Bool)] = [
            (#selector(MainSplitViewController.chooseRoutineToDebug(_:)), true),
            (#selector(MainSplitViewController.debugContinue(_:)), false),
            (#selector(MainSplitViewController.debugStepOver(_:)), true),
            (#selector(MainSplitViewController.debugStepInto(_:)), true),
            (#selector(MainSplitViewController.debugStepOut(_:)), false),
            (#selector(MainSplitViewController.debugStop(_:)), true),
            (#selector(MainSplitViewController.toggleBreakpoint(_:)), true),
            (#selector(MainSplitViewController.removeAllBreakpoints(_:)), false),
        ]
        for (selector, enabled) in expected {
            #expect(
                MainSplitViewController.resolvedEnablement(selector, context: context) == enabled,
                "\(NSStringFromSelector(selector))"
            )
        }

        var disconnected = context
        disconnected.isConnected = false
        #expect(MainSplitViewController.resolvedEnablement(
            #selector(MainSplitViewController.chooseRoutineToDebug(_:)), context: disconnected
        ) == false)

        var agent = context
        agent.isAgentMode = true
        for (selector, _) in expected {
            #expect(
                MainSplitViewController.resolvedEnablement(selector, context: agent) == false,
                "\(NSStringFromSelector(selector))"
            )
        }
    }
}
