//
//  MainMenuBuilderTests.swift
//  TableProTests
//
//  Pins the menu bar's structure: HIG menu order, title uniqueness (System
//  Settings binds an App Shortcut to a menu item's exact literal title), key
//  equivalent uniqueness (AppKit silently blanks the loser when two items claim
//  one combo), and complete coverage of every customizable shortcut.
//

import AppKit
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private func buildMenu(_ keyboard: KeyboardSettings = KeyboardSettings()) -> NSMenu {
    MainMenuBuilder.build(keyboard: keyboard)
}

/// Skips the Services submenu: assigning it to `NSApp.servicesMenu` hands it to
/// AppKit, which fills it with its own targeted items.
private func flatten(_ menu: NSMenu) -> [NSMenuItem] {
    menu.items.flatMap { item -> [NSMenuItem] in
        guard let submenu = item.submenu, submenu !== NSApp.servicesMenu else { return [item] }
        return [item] + flatten(submenu)
    }
}

@MainActor
struct MainMenuStructureTests {
    @Test("What's New stays reachable from Help without an active connection")
    func changelogIsReachable() throws {
        let help = try #require(buildMenu().items.first { $0.title == String(localized: "Help") }?.submenu)
        let item = try #require(help.items.first { $0.title == String(localized: "What's New") })
        #expect(item.action == #selector(AppDelegate.openChangelog(_:)))
        #expect(item.target == nil)
        #expect(item.keyEquivalent.isEmpty)
        #expect(AppDelegate().validateMenuItem(item))
        #expect(MainMenuLink.changelog == "https://docs.tablepro.app/changelog")
    }

    @Test("Top level order follows the macOS HIG")
    func topLevelOrder() {
        let titles = buildMenu().items.map(\.title)
        #expect(titles == [
            "TablePro",
            String(localized: "File"),
            String(localized: "Edit"),
            String(localized: "View"),
            String(localized: "Database"),
            String(localized: "Query"),
            String(localized: "Window"),
            String(localized: "Help")
        ])
    }

    @Test("Custom menus sit between View and Window")
    func customMenuPlacement() {
        let titles = buildMenu().items.map(\.title)
        let view = try? #require(titles.firstIndex(of: String(localized: "View")))
        let window = try? #require(titles.firstIndex(of: String(localized: "Window")))
        let database = try? #require(titles.firstIndex(of: String(localized: "Database")))
        #expect(view ?? 0 < database ?? 0)
        #expect(database ?? 0 < window ?? 0)
    }

    @Test("No two menu items share a title")
    func titlesAreUnique() {
        let titles = flatten(buildMenu())
            .filter { !$0.isSeparatorItem && $0.submenu == nil }
            .map(\.title)
        let duplicates = Dictionary(grouping: titles, by: { $0 }).filter { $0.value.count > 1 }.keys
        #expect(duplicates.isEmpty, "Duplicate menu titles break System Settings shortcut binding: \(duplicates)")
    }

    @Test("No two menu items claim the same key equivalent")
    func keyEquivalentsAreUnique() {
        let bound = flatten(buildMenu())
            .filter { !$0.keyEquivalent.isEmpty }
            .map { "\($0.keyEquivalentModifierMask.rawValue)-\($0.keyEquivalent)" }
        let duplicates = Dictionary(grouping: bound, by: { $0 }).filter { $0.value.count > 1 }.keys
        #expect(duplicates.isEmpty, "AppKit blanks the loser when two items claim one combo: \(duplicates)")
    }

    /// A menu builder that hardcodes a key equivalent takes that combo off the table for every
    /// `ShortcutAction`, and only `reservedAppShortcuts` tells the recorder so. Nothing else
    /// forces the two to agree, so a hardcoded item added without a matching entry ships a
    /// binding the recorder accepts and AppKit then blanks.
    @Test("Every hardcoded menu key equivalent is reserved against user binding")
    func hardcodedKeyEquivalentsAreReserved() {
        func canonical(_ key: BoundKey) -> String? {
            key.menuKeyEquivalent.map { "\(key.modifierFlags.rawValue)-\($0)" }
        }

        let keyboard = KeyboardSettings()
        let customizable = Set(ShortcutAction.allCases.compactMap { keyboard.shortcut(for: $0).flatMap(canonical) })
        let reserved = Set(ShortcutAction.reservedAppShortcuts.compactMap { canonical($0.key) })

        let hardcoded = flatten(buildMenu())
            .filter { !$0.keyEquivalent.isEmpty }
            .map { (combo: "\($0.keyEquivalentModifierMask.rawValue)-\($0.keyEquivalent)", title: $0.title) }
            .filter { !customizable.contains($0.combo) }
        #expect(!hardcoded.isEmpty, "Found no hardcoded menu shortcuts, so this guard would pass vacuously")

        let unreserved = hardcoded.filter { !reserved.contains($0.combo) }.map(\.title)
        #expect(unreserved.isEmpty, "Hardcoded menu shortcuts missing from reservedAppShortcuts: \(unreserved)")
    }

    @Test("Every menu item carries an action")
    func everyItemHasAnAction() {
        let dead = flatten(buildMenu())
            .filter { !$0.isSeparatorItem && $0.submenu == nil && $0.action == nil }
            .map(\.title)
        #expect(dead.isEmpty, "Items without an action can never enable: \(dead)")
    }

    /// Only leaf commands are checked. AppKit points a submenu container at its own
    /// `submenuAction:`, and it owns Window and Help outright once they are assigned
    /// to `NSApp.windowsMenu` / `NSApp.helpMenu`.
    @Test("Every authored command leaves its target nil so the responder chain resolves it")
    func targetsAreNil() {
        let systemOwned = [String(localized: "Window"), String(localized: "Help")]
        let targeted = buildMenu().items
            .filter { !systemOwned.contains($0.title) }
            .compactMap(\.submenu)
            .flatMap(flatten)
            .filter { !$0.isSeparatorItem && $0.submenu == nil && $0.target != nil }
            .map(\.title)
        #expect(targeted.isEmpty, "A fixed target bypasses responder-chain validation: \(targeted)")
    }
}

@MainActor
struct MainMenuShortcutCoverageTests {
    @Test("Every customizable action reaches exactly one menu item")
    func everyShortcutActionIsReachable() {
        let identifiers = flatten(buildMenu()).compactMap(\.identifier?.rawValue)
        for action in ShortcutAction.allCases {
            let expected = MenuItemFactory.identifier(for: action).rawValue
            let matches = identifiers.filter { $0 == expected }.count
            #expect(matches == 1, "\(action.rawValue) is bound to \(matches) menu items, expected 1")
        }
    }

    @Test("A rebound shortcut reaches the built menu")
    func reboundShortcutApplies() {
        let menu = buildMenu()
        var keyboard = KeyboardSettings()
        keyboard.shortcuts[ShortcutAction.executeQuery.rawValue] = .character("j", command: true, shift: true)
        MainMenuKeyEquivalentSync.apply(keyboard: keyboard, to: menu)

        let target = MenuItemFactory.identifier(for: .executeQuery)
        let item = flatten(menu).first { $0.identifier == target }
        #expect(item?.keyEquivalent == "j")
        #expect(item?.keyEquivalentModifierMask == [.command, .shift])
    }

    /// `Cmd+Option+F` is Apple's Find and Replace key, so the filter bar moved off it rather than a
    /// documented text-editing shortcut landing somewhere users would not look for it.
    @Test("The find keys are Apple's and the filter bar sits beside them")
    func findAndFilterDefaultsHold() {
        #expect(KeyboardSettings.defaultShortcuts[.find] == .character("f", command: true))
        #expect(KeyboardSettings.defaultShortcuts[.findAndReplace] == .character("f", command: true, option: true))
        #expect(KeyboardSettings.defaultShortcuts[.findNext] == .character("g", command: true))
        #expect(KeyboardSettings.defaultShortcuts[.findPrevious] == .character("g", command: true, shift: true))
        #expect(KeyboardSettings.defaultShortcuts[.useSelectionForFind] == .character("e", command: true))
        #expect(KeyboardSettings.defaultShortcuts[.toggleFilters] == .character("f", command: true, shift: true))
        #expect(
            KeyboardSettings.defaultShortcuts[.focusSidebarSearch]
                == .character("f", command: true, option: true, control: true)
        )
    }

    @Test("Cmd+F is customizable rather than reserved")
    func commandFIsNoLongerReserved() {
        let commandF = BoundKey.character("f", command: true)
        #expect(!ShortcutAction.reservedAppShortcuts.contains { $0.key == commandF })
        #expect(!ShortcutAction.editorBuiltIns.contains { $0.key == commandF })
        #expect(ShortcutAction.reservedConflict(for: commandF, context: .dataGrid) == nil)
        #expect(ShortcutAction.reservedConflict(for: commandF, context: .editor) == nil)
    }

    @Test("Cmd+F for the filter bar is no longer refused outright, only reported against Find")
    func recorderReportsFindRatherThanRefusingCommandF() {
        let commandF = BoundKey.character("f", command: true)
        #expect(ShortcutAction.reservedConflict(for: commandF, context: ShortcutAction.toggleFilters.context) == nil)
        #expect(KeyboardSettings.default.findConflict(for: commandF, excluding: .toggleFilters) == .find)
    }

    @Test("Cmd+F parked on Find Next is still reported against a later claim from the filter bar")
    func commandFOnFindNextStillConflictsWithFilterBar() {
        let commandF = BoundKey.character("f", command: true)
        var keyboard = KeyboardSettings()
        keyboard.setShortcut(commandF, for: .findNext)

        #expect(keyboard.findConflict(for: commandF, excluding: .toggleFilters) == .findNext)
        #expect(keyboard.findConflict(for: commandF, excluding: .find) == .findNext)
    }

    @Test("A grid binding conflicts with Find Next, which owns a window-wide key equivalent")
    func gridBindingConflictsWithFindNext() {
        let commandG = BoundKey.character("g", command: true)
        #expect(KeyboardSettings.defaultShortcuts[.findNext] == commandG)
        #expect(KeyboardSettings.default.findConflict(for: commandG, excluding: .nextPage) == .findNext)
    }

    @Test("Every find command shares one context so none can be shadowed by a grid binding")
    func findCommandsAreGlobal() {
        #expect(ShortcutAction.find.context == .global)
        #expect(ShortcutAction.findNext.context == .global)
        #expect(ShortcutAction.findPrevious.context == .global)
    }

    @Test("Reassigning Cmd+F leaves Find on its default so it recovers when the filter bar moves back")
    func reassigningCommandFDoesNotStrandFind() {
        var keyboard = KeyboardSettings()
        #expect(!keyboard.isCustomized(.find))

        keyboard.setShortcut(.character("f", command: true), for: .toggleFilters)
        #expect(keyboard.shortcut(for: .find) == nil)
        #expect(!keyboard.isCustomized(.find))

        keyboard.setShortcut(.character("f", command: true, option: true), for: .toggleFilters)
        #expect(keyboard.shortcut(for: .find) == .character("f", command: true))
    }

    @Test("Find yields Cmd+F to a user-bound filter bar instead of sharing it")
    func findYieldsCommandFToFilterBar() {
        var keyboard = KeyboardSettings()
        keyboard.setShortcut(.character("f", command: true), for: .toggleFilters)

        #expect(keyboard.shortcut(for: .find) == nil)
        #expect(keyboard.shortcut(for: .toggleFilters) == .character("f", command: true))

        let menu = buildMenu()
        MainMenuKeyEquivalentSync.apply(keyboard: keyboard, to: menu)
        let claimants = flatten(menu).filter {
            $0.keyEquivalent == "f" && $0.keyEquivalentModifierMask == [.command]
        }
        #expect(claimants.count == 1)
        #expect(claimants.first?.identifier == MenuItemFactory.identifier(for: .toggleFilters))
    }

    @Test("Find… carries no hardcoded key equivalent")
    func findMenuItemFollowsKeyboardSettings() {
        var keyboard = KeyboardSettings()
        keyboard.setShortcut(.character("f", command: true, shift: true), for: .find)

        let menu = buildMenu()
        MainMenuKeyEquivalentSync.apply(keyboard: keyboard, to: menu)
        let item = flatten(menu).first { $0.identifier == MenuItemFactory.identifier(for: .find) }
        #expect(item?.keyEquivalent == "f")
        #expect(item?.keyEquivalentModifierMask == [.command, .shift])
    }

    /// The eight commands the revamp made rebindable. Each was reachable only by pointer before:
    /// two segments of a toolbar control, an Edit menu item with no action identifier at all, and
    /// five buttons inside Agent mode's rail and the assistant pane's header menu.
    private static let displacedCommands: [(action: ShortcutAction, title: String)] = [
        (.showTablesList, String(localized: "Show Tables")),
        (.showFavoritesList, String(localized: "Show Favorites")),
        (.restorePreviousValues, String(localized: "Restore Previous Values…")),
        (.newAgentSession, String(localized: "New Session")),
        (.openAgentSession, String(localized: "Open Session")),
        (.closeAgentSession, String(localized: "Close Session")),
        (.deleteAgentSession, String(localized: "Delete Session…")),
        (.newAIConversation, String(localized: "New Conversation")),
    ]

    @Test("Each newly rebindable command is stamped on the menu item that runs it")
    func displacedCommandsReachTheirMenuItem() {
        let items = flatten(buildMenu())
        for command in Self.displacedCommands {
            let matches = items.filter { $0.identifier == MenuItemFactory.identifier(for: command.action) }
            #expect(matches.count == 1, "\(command.action.rawValue) is on \(matches.count) items, expected 1")
            #expect(matches.first?.title == command.title, "\(command.action.rawValue) is on the wrong item")
        }
    }

    /// Shipped unbound on purpose. Every combo a reasonable person would reach for is taken, and a
    /// default that displaced a shipped one would be a worse trade than an unassigned row in
    /// Settings, which is where these are now visible for the first time.
    @Test("Each newly rebindable command ships with no key equivalent of its own")
    func displacedCommandsShipUnbound() {
        let items = flatten(buildMenu())
        for command in Self.displacedCommands {
            #expect(KeyboardSettings.defaultShortcuts[command.action] == nil, "\(command.action.rawValue)")
            let item = items.first { $0.identifier == MenuItemFactory.identifier(for: command.action) }
            #expect(item?.keyEquivalent.isEmpty == true, "\(command.action.rawValue) arrived with a binding")
        }
    }

    /// Settings lists every action by this name, so two sharing one would offer the user two
    /// identical rows and no way to tell which command they were rebinding.
    @Test("No two actions share a display name")
    func displayNamesAreUnique() {
        let names = ShortcutAction.allCases.map(\.displayName)
        let duplicates = Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }.keys
        #expect(duplicates.isEmpty, "Two shortcut actions share a name in Settings: \(duplicates)")
    }

    @Test("Jump to Column… sits in the Edit menu's Find submenu on Cmd+Shift+J")
    func jumpToColumnLivesUnderFind() {
        let edit = buildMenu().items.first { $0.title == String(localized: "Edit") }?.submenu
        let find = edit?.items.first { $0.title == String(localized: "Find") }?.submenu
        let item = find?.items.first { $0.identifier == MenuItemFactory.identifier(for: .jumpToColumn) }

        #expect(item?.title == String(localized: "Jump to Column…"))
        #expect(item?.action == #selector(MainSplitViewController.jumpToColumn(_:)))
        #expect(item?.keyEquivalent == "j")
        #expect(item?.keyEquivalentModifierMask == [.command, .shift])
    }
}

/// Agent mode's sessions and the assistant's conversations had no menu-bar home at all: the rail's
/// buttons and the trailing pane's header menu were the only routes, so none of the seven commands
/// could be found by search, rebound, or reached with the rail collapsed or the pane closed.
@MainActor
struct FileSessionMenuTests {
    private func sessionMenu() -> NSMenu? {
        buildMenu().items.first { $0.title == String(localized: "File") }?
            .submenu?.items.first { $0.title == String(localized: "Session") }?
            .submenu
    }

    @Test("The submenu carries the session lifecycle and the conversation commands, in that order")
    func sessionMenuOrder() throws {
        let titles = try #require(sessionMenu()).items.map(\.title)
        #expect(titles == [
            String(localized: "New Session"),
            String(localized: "Open Session"),
            String(localized: "Recent Sessions"),
            String(localized: "Close Session"),
            String(localized: "Delete Session…"),
            "",
            String(localized: "New Conversation"),
            String(localized: "Conversation History"),
            String(localized: "Clear Recents…"),
        ])
    }

    /// The two list rows are exempt: AppKit points a submenu container at its own `submenuAction:`,
    /// and the rows inside are built by the delegate when the list opens.
    @Test("Every leaf carries an action and leaves its target nil")
    func everyLeafIsACommand() throws {
        let leaves = try #require(sessionMenu()).items.filter { !$0.isSeparatorItem && $0.submenu == nil }
        #expect(leaves.count == 6)
        for leaf in leaves {
            #expect(leaf.action != nil, "\(leaf.title) can never enable")
            #expect(leaf.target == nil, "\(leaf.title) bypasses responder-chain validation")
        }
    }

    /// AppKit ignores a key equivalent on an item that owns a submenu, so the command a user can
    /// rebind has to be a leaf. Open Session acts on the session the rail has highlighted, and the
    /// list beside it is how any other session is reached, exactly as Import Data… and Import Data
    /// From are split.
    @Test("Open Session is a leaf, so a binding it is given can fire")
    func openSessionIsALeaf() throws {
        let item = try #require(
            sessionMenu()?.items.first { $0.title == String(localized: "Open Session") }
        )
        #expect(item.submenu == nil)
        #expect(item.action == #selector(MainSplitViewController.openAgentSession(_:)))
        #expect(item.identifier == MenuItemFactory.identifier(for: .openAgentSession))
    }

    @Test("Both lists fill themselves when they open", arguments: [
        String(localized: "Recent Sessions"), String(localized: "Conversation History"),
    ])
    func listsAreDelegateDriven(title: String) throws {
        let submenu = try #require(sessionMenu()?.items.first { $0.title == title }?.submenu)
        #expect(submenu.delegate != nil, "The set changes while the menu is closed, so it is built on open")
        #expect(submenu.items.isEmpty, "The list is filled when it opens, not at build time")
    }

    /// `AIChatViewModel` is a plain `ObservableObject` and `AgentSessionRegistry` is not a responder,
    /// so a command named on either would reach nothing and AppKit would draw it dead. Every one of
    /// these names a window selector instead, including the two lists' rows.
    @Test("Each command reaches the window rather than a view model nothing can resolve")
    func everyCommandIsAWindowSelector() throws {
        var actions = try #require(sessionMenu()).items
            .filter { $0.submenu == nil }
            .compactMap(\.action)
        #expect(actions.count == 6)
        actions.append(contentsOf: [AgentSessionMenuDelegate.action, ConversationHistoryMenuDelegate.action])
        for action in actions {
            #expect(
                MainSplitViewController.instancesRespond(to: action),
                "\(NSStringFromSelector(action)) reaches nothing, so AppKit draws it dead"
            )
        }
    }
}

@MainActor
struct MainMenuValidationTests {
    private func enabled(_ selector: Selector, _ context: MenuValidationContext) -> Bool {
        MainSplitViewController.isEnabled(selector, context: context)
    }

    @Test("Disconnected windows disable connection-scoped commands")
    func disconnectedDisablesCommands() {
        let context = MenuValidationContext()
        #expect(!enabled(#selector(MainSplitViewController.executeQuery(_:)), context))
        #expect(!enabled(#selector(MainSplitViewController.refreshDatabase(_:)), context))
        #expect(!enabled(#selector(MainSplitViewController.exportTables(_:)), context))
    }

    @Test("Back and Forward need a connection and a history of their own")
    func backAndForwardNeedTheirOwnHistory() {
        var context = MenuValidationContext()
        context.canNavigateBack = true
        context.canNavigateForward = true
        #expect(!enabled(#selector(MainSplitViewController.navigateBack(_:)), context))
        #expect(!enabled(#selector(MainSplitViewController.navigateForward(_:)), context))

        context.isConnected = true
        #expect(enabled(#selector(MainSplitViewController.navigateBack(_:)), context))
        #expect(enabled(#selector(MainSplitViewController.navigateForward(_:)), context))

        context.canNavigateBack = false
        #expect(!enabled(#selector(MainSplitViewController.navigateBack(_:)), context))
        #expect(enabled(#selector(MainSplitViewController.navigateForward(_:)), context))
    }

    @Test("Execute needs both a connection and query text")
    func executeNeedsQueryText() {
        var context = MenuValidationContext()
        context.isConnected = true
        #expect(!enabled(#selector(MainSplitViewController.executeQuery(_:)), context))
        context.hasQueryText = true
        #expect(enabled(#selector(MainSplitViewController.executeQuery(_:)), context))
    }

    /// Redis declares no plan, and the menu item used to validate on the query text alone, so
    /// `Cmd+Option+E` ran a `DEBUG OBJECT` the server refuses while the bar's button was dimmed.
    @Test("Explain Query needs an engine that declares a plan")
    func explainNeedsADeclaredPlan() {
        var context = MenuValidationContext()
        context.isConnected = true
        context.hasQueryText = true
        #expect(!enabled(#selector(MainSplitViewController.explainQuery(_:)), context))
        context.supportsExplain = true
        #expect(enabled(#selector(MainSplitViewController.explainQuery(_:)), context))
    }

    /// `runExplain` returns at its first guard while the tab runs, so a lit item did nothing.
    @Test("Explain Query dims while the tab is running a query")
    func explainDimsWhileExecuting() {
        var context = MenuValidationContext()
        context.isConnected = true
        context.hasQueryText = true
        context.supportsExplain = true
        context.isQueryExecuting = true
        #expect(!enabled(#selector(MainSplitViewController.explainQuery(_:)), context))
    }

    @Test("Explain Query answers exactly what the editor bar's Explain answers")
    func explainAgreesWithTheEditorBar() {
        let variant = ExplainVariant(id: "plain", label: "Explain", sqlPrefix: "EXPLAIN")
        for isConnected in [true, false] {
            for hasQueryText in [true, false] {
                for isExecuting in [true, false] {
                    for supportsExplain in [true, false] {
                        var context = MenuValidationContext()
                        context.isConnected = isConnected
                        context.hasQueryText = hasQueryText
                        context.isQueryExecuting = isExecuting
                        context.supportsExplain = supportsExplain
                        let bar = QueryCommandAvailability(
                            isConnected: isConnected,
                            hasQueryText: hasQueryText,
                            isExecuting: isExecuting,
                            isStoppable: true,
                            hasResults: false,
                            explainVariants: supportsExplain ? [variant] : [],
                            shortcutHint: { label, _ in label }
                        )
                        #expect(enabled(#selector(MainSplitViewController.explainQuery(_:)), context) == bar.canExplain)
                    }
                }
            }
        }
    }

    /// #2172: `paste:` had no window-level implementation at all, so with focus anywhere that does
    /// not paste, AppKit disabled the item, and a disabled item still owns its key equivalent, so
    /// Command+V was swallowed for the whole window. Adding the handler without an explicit arm
    /// here would have been just as wrong in the other direction: `isEnabled` ends in
    /// `default: return true`, which would have shipped Paste permanently lit.
    @Test("Paste needs a connection and somewhere for the rows to land")
    func pasteNeedsSomewhereToLand() {
        var context = MenuValidationContext()
        context.canPasteRows = true
        #expect(!enabled(#selector(MainSplitViewController.paste(_:)), context))
        context.isConnected = true
        #expect(enabled(#selector(MainSplitViewController.paste(_:)), context))
        context.canPasteRows = false
        #expect(!enabled(#selector(MainSplitViewController.paste(_:)), context))
    }

    /// A database view opens as a `.table` tab with `tableContext.isEditable` false, so tab type
    /// alone would light Paste over content the row paste must never write to.
    @Test("Paste needs the tab to be editable, not merely a table tab")
    func pasteNeedsAnEditableTab() {
        var context = MenuValidationContext()
        context.isConnected = true
        context.canPasteRows = false
        #expect(!enabled(#selector(MainSplitViewController.paste(_:)), context))
    }

    @Test("Paste is answered by its own arm, never by the default that enables everything else")
    func pasteIsNotAnsweredByTheDefaultArm() {
        let context = MenuValidationContext(hasSelectedWorkspace: true, isConnected: true)
        #expect(!enabled(#selector(MainSplitViewController.paste(_:)), context))
    }

    @Test("Save needs pending changes and a writable connection")
    func saveNeedsPendingChanges() {
        var context = MenuValidationContext()
        context.isConnected = true
        context.hasPendingChanges = true
        #expect(enabled(#selector(MainSplitViewController.saveDocument(_:)), context))
        context.isReadOnly = true
        #expect(!enabled(#selector(MainSplitViewController.saveDocument(_:)), context))
    }

    /// Both handlers return at their first guard in states the old validation called enabled, so
    /// the item stayed lit and the click did nothing at all.
    @Test("Save As needs a query tab, not just a connection")
    func saveAsNeedsAQueryTab() {
        var context = MenuValidationContext()
        context.isConnected = true
        #expect(!enabled(#selector(MainSplitViewController.saveDocumentAs(_:)), context))
        context.isQueryTab = true
        #expect(enabled(#selector(MainSplitViewController.saveDocumentAs(_:)), context))
    }

    @Test("Export Results needs rows to export")
    func exportResultsNeedsRows() {
        var context = MenuValidationContext()
        context.isConnected = true
        #expect(!enabled(#selector(MainSplitViewController.exportQueryResults(_:)), context))
        context.hasResultRows = true
        #expect(enabled(#selector(MainSplitViewController.exportQueryResults(_:)), context))
    }

    @Test("Neither survives losing the connection")
    func bothStillNeedAConnection() {
        var context = MenuValidationContext()
        context.isQueryTab = true
        context.hasResultRows = true
        #expect(!enabled(#selector(MainSplitViewController.saveDocumentAs(_:)), context))
        #expect(!enabled(#selector(MainSplitViewController.exportQueryResults(_:)), context))
    }

    @Test("Read-only connections block destructive commands")
    func readOnlyBlocksMutations() {
        var context = MenuValidationContext()
        context.isConnected = true
        context.isCurrentTabEditable = true
        context.isCurrentTabSchemaResolved = true
        context.hasTableSelection = true
        context.canTruncateSelectedTables = true
        context.isReadOnly = true
        #expect(!enabled(#selector(MainSplitViewController.addRow(_:)), context))
        #expect(!enabled(#selector(MainSplitViewController.truncateTable(_:)), context))
        #expect(!enabled(#selector(MainSplitViewController.createNewTable(_:)), context))
    }

    /// A view is a valid selection and a hopeless truncate. The menu bar used to ask only whether
    /// anything was selected, so it offered Truncate Table for one and the server refused the save.
    @Test("Truncate Table is disabled for a selection holding nothing truncatable")
    func truncateNeedsATruncatableSelection() {
        var context = MenuValidationContext()
        context.isConnected = true
        context.hasTableSelection = true
        context.canTruncateSelectedTables = false
        #expect(!enabled(#selector(MainSplitViewController.truncateTable(_:)), context))

        context.canTruncateSelectedTables = true
        #expect(enabled(#selector(MainSplitViewController.truncateTable(_:)), context))
    }

    @Test("Cancel Query tracks execution, not connection")
    func cancelTracksExecution() {
        var context = MenuValidationContext()
        #expect(!enabled(#selector(MainSplitViewController.cancelQuery(_:)), context))
        context.isQueryExecuting = true
        context.isQueryStoppable = true
        #expect(enabled(#selector(MainSplitViewController.cancelQuery(_:)), context))
    }

    /// A batch whose `COMMIT` is on the wire is executing and unstoppable at the same time, and
    /// `Cmd+.` has to dim rather than fire into work nothing can interrupt.
    @Test("Cancel Query dims while a batch is committing")
    func cancelDimsWhileCommitting() {
        var context = MenuValidationContext()
        context.isQueryExecuting = true
        context.isQueryStoppable = false
        #expect(!enabled(#selector(MainSplitViewController.cancelQuery(_:)), context))
    }

    @Test("Filter bar needs an active table result grid")
    func filterBarNeedsTableResultGrid() {
        var context = MenuValidationContext()
        context.isConnected = true
        #expect(!enabled(#selector(MainSplitViewController.toggleFilterBar(_:)), context))
        context.canUseTableResultCommands = true
        #expect(enabled(#selector(MainSplitViewController.toggleFilterBar(_:)), context))
    }

    @Test("Highlight Rules needs a connected data grid with columns")
    func highlightRulesNeedsDataGrid() {
        var context = MenuValidationContext()
        context.canPresentHighlightRules = true
        #expect(!enabled(#selector(MainSplitViewController.showHighlightRules(_:)), context))
        context.isConnected = true
        #expect(enabled(#selector(MainSplitViewController.showHighlightRules(_:)), context))
        context.canPresentHighlightRules = false
        #expect(!enabled(#selector(MainSplitViewController.showHighlightRules(_:)), context))
    }

    @Test("Capability flags gate driver-specific commands")
    func capabilitiesGateCommands() {
        var context = MenuValidationContext()
        context.isConnected = true
        #expect(!enabled(#selector(MainSplitViewController.showServerDashboard(_:)), context))
        #expect(!enabled(#selector(MainSplitViewController.showUsersAndRoles(_:)), context))
        #expect(!enabled(#selector(MainSplitViewController.openContainerSwitcher(_:)), context))
        context.supportsServerDashboard = true
        context.supportsUserManagement = true
        context.supportsContainerSwitching = true
        #expect(enabled(#selector(MainSplitViewController.showServerDashboard(_:)), context))
        #expect(enabled(#selector(MainSplitViewController.showUsersAndRoles(_:)), context))
        #expect(enabled(#selector(MainSplitViewController.openContainerSwitcher(_:)), context))
    }

    /// Everything a connection-scoped command could also need is switched on, so `isConnected`
    /// is the only thing left that can disable them.
    private func capableContext(phase: ConnectionWindowPhase, pane: ConnectionWindowPane) -> MenuValidationContext {
        var context = capableContext()
        context.isConnected = MainSplitViewController.isConnected(phase: phase, pane: pane)
        return context
    }

    private func capableContext() -> MenuValidationContext {
        var context = MenuValidationContext()
        context.canUseTableResultCommands = true
        context.canPresentHighlightRules = true
        context.canNavigatePages = true
        context.isQueryTab = true
        context.hasResultRows = true
        context.hasQueryText = true
        context.supportsExplain = true
        context.hasPendingChanges = true
        context.hasDataPendingChanges = true
        context.hasImportFormats = true
        context.supportsBackup = true
        context.supportsRestore = true
        context.supportsContainerSwitching = true
        context.supportsServerDashboard = true
        context.supportsUserManagement = true
        context.isCurrentTabEditable = true
        context.isCurrentTabSchemaResolved = true
        context.hasTableSelection = true
        context.hasRowSelection = true
        context.canTruncateSelectedTables = true
        context.canDropSelectedTables = true
        context.canShowTableStructure = true
        context.canEditViewDefinition = true
        context.hasMaintenanceOperations = true
        context.canInsertDocument = true
        return context
    }

    /// A window whose coordinator is alive is exactly the case the old `coordinator != nil`
    /// check got wrong, so every phase is resolved with a renderable session behind it.
    private func livePane(for phase: ConnectionWindowPhase) -> ConnectionWindowPane {
        ConnectionWindowPaneResolver.pane(phase: phase, hasConnection: true, hasRenderableSession: true)
    }

    private var connectionScopedSelectors: [Selector] {
        [
            #selector(MainSplitViewController.refreshDatabase(_:)),
            #selector(MainSplitViewController.exportTables(_:)),
            #selector(MainSplitViewController.openQuickSwitcher(_:)),
            #selector(MainSplitViewController.goToNextPage(_:)),
            #selector(MainSplitViewController.saveDocument(_:)),
            #selector(MainSplitViewController.saveDocumentAs(_:)),
            #selector(MainSplitViewController.importData(_:)),
            #selector(MainSplitViewController.backupDatabase(_:)),
            #selector(MainSplitViewController.restoreDatabase(_:)),
            #selector(MainSplitViewController.executeQuery(_:)),
            #selector(MainSplitViewController.explainQuery(_:)),
            #selector(MainSplitViewController.previewSQL(_:)),
            #selector(MainSplitViewController.createNewTable(_:)),
            #selector(MainSplitViewController.openContainerSwitcher(_:)),
            #selector(MainSplitViewController.showServerDashboard(_:)),
            #selector(MainSplitViewController.showUsersAndRoles(_:)),
            #selector(MainSplitViewController.toggleFilterBar(_:)),
            #selector(MainSplitViewController.showHighlightRules(_:))
        ]
    }

    /// Gated on a grid, a tab or a sidebar selection the coordinator keeps across a lost session,
    /// so each one needs the connection too or it stays lit over the unavailable pane.
    private var contentScopedSelectors: [Selector] {
        [
            #selector(MainSplitViewController.addRow(_:)),
            #selector(MainSplitViewController.duplicateRow(_:)),
            #selector(MainSplitViewController.insertDocument(_:)),
            #selector(MainSplitViewController.truncateTable(_:)),
            #selector(MainSplitViewController.delete(_:)),
            #selector(MainSplitViewController.showTableStructure(_:)),
            #selector(MainSplitViewController.editViewDefinition(_:)),
            #selector(MainSplitViewController.runMaintenanceOperation(_:))
        ]
    }

    /// Both commands pre-fill from the schema's account of which columns the server fills in, so
    /// they stay disabled until it arrives rather than staging NULL into an identity column.
    @Test("Add Row and Duplicate Row wait for the schema to resolve")
    func rowInsertionWaitsForTheSchema() {
        var context = capableContext()
        context.isConnected = true
        context.isCurrentTabSchemaResolved = false
        #expect(!enabled(#selector(MainSplitViewController.addRow(_:)), context))
        #expect(!enabled(#selector(MainSplitViewController.duplicateRow(_:)), context))
        context.isCurrentTabSchemaResolved = true
        #expect(enabled(#selector(MainSplitViewController.addRow(_:)), context))
        #expect(enabled(#selector(MainSplitViewController.duplicateRow(_:)), context))
    }

    @Test("Insert Document stays dimmed on an engine without whole-document writes")
    func insertDocumentNeedsADocumentEngine() {
        var context = capableContext()
        context.isConnected = true
        #expect(enabled(#selector(MainSplitViewController.insertDocument(_:)), context))
        context.canInsertDocument = false
        #expect(!enabled(#selector(MainSplitViewController.insertDocument(_:)), context))
    }

    @Test("A read-only connection dims Insert Document")
    func insertDocumentRespectsReadOnly() {
        var context = capableContext()
        context.isConnected = true
        context.isReadOnly = true
        #expect(!enabled(#selector(MainSplitViewController.insertDocument(_:)), context))
    }

    @Test("A stale selection does not keep content commands enabled without a connection")
    func contentCommandsNeedTheConnection() {
        var context = capableContext()
        context.isConnected = false
        for selector in contentScopedSelectors {
            #expect(!enabled(selector, context), "\(selector) stayed enabled without a connection")
        }
        context.isConnected = true
        for selector in contentScopedSelectors {
            #expect(enabled(selector, context), "\(selector) stayed disabled while connected")
        }
    }

    @Test("Only a connected phase enables connection-scoped commands")
    func onlyConnectedPhaseEnablesCommands() {
        let disabled: [ConnectionWindowPhase] = [
            .idle,
            .connecting,
            .unavailable(.notConnected),
            .unavailable(.cancelled),
            .unavailable(.disconnected(nil)),
            .unavailable(.disconnectedByUser),
            .unavailable(.failed(ConnectionFailureInfo(message: "connection refused"))),
            .unavailable(.actionRequired(ConnectionFailureInfo(message: "plugin missing"), .installPlugin)),
            .closing
        ]
        let gated = connectionScopedSelectors + contentScopedSelectors
        for phase in disabled {
            let context = capableContext(phase: phase, pane: livePane(for: phase))
            for selector in gated {
                #expect(!enabled(selector, context), "\(selector) stayed enabled in phase \(phase)")
            }
        }

        let connected = capableContext(phase: .connected, pane: livePane(for: .connected))
        for selector in gated {
            #expect(enabled(selector, connected), "\(selector) stayed disabled while connected")
        }
    }

    @Test("A connected phase with nothing renderable enables nothing")
    func connectedWithoutRenderableSessionStaysDisabled() {
        let pane = ConnectionWindowPaneResolver.pane(
            phase: .connected,
            hasConnection: true,
            hasRenderableSession: false
        )
        let context = capableContext(phase: .connected, pane: pane)
        #expect(!context.isConnected)
        #expect(!enabled(#selector(MainSplitViewController.executeQuery(_:)), context))
    }

    @Test("Connection state comes from the phase, not from a surviving object graph")
    func connectionStateFollowsPhase() {
        #expect(MainSplitViewController.isConnected(phase: .connected, pane: .content))
        #expect(!MainSplitViewController.isConnected(phase: .connecting, pane: .connecting))
        #expect(!MainSplitViewController.isConnected(phase: .idle, pane: .content))
        #expect(!MainSplitViewController.isConnected(phase: .closing, pane: .empty))
        #expect(!MainSplitViewController.isConnected(
            phase: .unavailable(.disconnectedByUser),
            pane: .unavailable(.disconnectedByUser)
        ))
    }

    @Test("Find needs an editor or a mounted data grid, not merely a result that can be filtered")
    func findNeedsAnEditor() {
        var context = MenuValidationContext()
        context.isConnected = true
        #expect(!enabled(#selector(MainSplitViewController.performFind(_:)), context))
        #expect(!enabled(#selector(MainSplitViewController.findNext(_:)), context))
        #expect(!enabled(#selector(MainSplitViewController.findPrevious(_:)), context))
        context.canUseTableResultCommands = true
        #expect(!enabled(#selector(MainSplitViewController.performFind(_:)), context))
        context.canUseGridFindCommands = true
        #expect(enabled(#selector(MainSplitViewController.performFind(_:)), context))
        #expect(!enabled(#selector(MainSplitViewController.findNext(_:)), context))
        context.canUseTableResultCommands = false
        context.canUseGridFindCommands = false
        context.hasEditorForFind = true
        #expect(enabled(#selector(MainSplitViewController.performFind(_:)), context))
        #expect(enabled(#selector(MainSplitViewController.findNext(_:)), context))
        #expect(enabled(#selector(MainSplitViewController.findPrevious(_:)), context))
    }

    @Test("An unknown selector stays enabled so the chain can answer for it")
    func unknownSelectorsFallThrough() {
        #expect(enabled(#selector(NSWindow.performClose(_:)), MenuValidationContext()))
    }

    @Test("Object commands need exactly one selected object")
    func objectCommandsNeedSingleSelection() {
        var context = MenuValidationContext()
        context.isConnected = true
        #expect(!enabled(#selector(MainSplitViewController.showTableStructure(_:)), context))
        #expect(!enabled(#selector(MainSplitViewController.editViewDefinition(_:)), context))
        context.canShowTableStructure = true
        #expect(enabled(#selector(MainSplitViewController.showTableStructure(_:)), context))
        #expect(!enabled(#selector(MainSplitViewController.editViewDefinition(_:)), context))
        context.canEditViewDefinition = true
        #expect(enabled(#selector(MainSplitViewController.editViewDefinition(_:)), context))
    }

    /// The sidebar hides Edit View Definition on a read-only connection. The menu bar used to leave
    /// it enabled, so it opened the definition and the save then failed at the gate.
    @Test("Editing a view definition is disabled on a read-only connection")
    func editViewDefinitionNeedsWriteAccess() {
        var context = MenuValidationContext()
        context.isConnected = true
        context.canEditViewDefinition = true
        #expect(enabled(#selector(MainSplitViewController.editViewDefinition(_:)), context))
        context.isReadOnly = true
        #expect(!enabled(#selector(MainSplitViewController.editViewDefinition(_:)), context))
    }

    /// Reading a definition writes nothing, so these stay available on a read-only connection,
    /// exactly as the sidebar offers them there.
    @Test("Show DDL and Copy DDL need a view and survive read-only")
    func ddlCommandsFollowTheSelectedObject() {
        var context = MenuValidationContext()
        context.isConnected = true
        #expect(!enabled(#selector(MainSplitViewController.showObjectDDL(_:)), context))
        #expect(!enabled(#selector(MainSplitViewController.copyObjectDDL(_:)), context))
        context.canShowObjectDDL = true
        #expect(enabled(#selector(MainSplitViewController.showObjectDDL(_:)), context))
        #expect(enabled(#selector(MainSplitViewController.copyObjectDDL(_:)), context))
        context.isReadOnly = true
        #expect(enabled(#selector(MainSplitViewController.showObjectDDL(_:)), context))
    }

    @Test("Refresh and Edit Comment need the driver and the object to support them")
    func refreshAndCommentNeedSupport() {
        var context = MenuValidationContext()
        context.isConnected = true
        #expect(!enabled(#selector(MainSplitViewController.refreshMaterializedView(_:)), context))
        #expect(!enabled(#selector(MainSplitViewController.editObjectComment(_:)), context))
        context.canRefreshMaterializedView = true
        context.canEditObjectComment = true
        #expect(enabled(#selector(MainSplitViewController.refreshMaterializedView(_:)), context))
        #expect(enabled(#selector(MainSplitViewController.editObjectComment(_:)), context))
    }

    @Test("Maintenance stays disabled when the driver offers no operations")
    func maintenanceNeedsOperations() {
        var context = MenuValidationContext()
        context.isConnected = true
        #expect(!enabled(#selector(MainSplitViewController.runMaintenanceOperation(_:)), context))
        context.hasMaintenanceOperations = true
        #expect(enabled(#selector(MainSplitViewController.runMaintenanceOperation(_:)), context))
    }

    /// Both are sidebar commands first. They are mirrored here so the feature is reachable from
    /// the keyboard, and they validate on the same facts the sidebar's own menu reads.
    @Test("Copying is offered only on an engine that can copy")
    func copyObjectsNeedsASQLEngine() {
        var context = MenuValidationContext()
        context.isConnected = true
        #expect(!enabled(#selector(MainSplitViewController.copyObjectsToDatabase(_:)), context))
        context.canCopyObjects = true
        #expect(enabled(#selector(MainSplitViewController.copyObjectsToDatabase(_:)), context))
    }

    @Test("Duplicate Database needs a driver that creates databases")
    func duplicateDatabaseNeedsContainers() {
        var context = MenuValidationContext()
        context.isConnected = true
        #expect(!enabled(#selector(MainSplitViewController.duplicateCurrentDatabase(_:)), context))
        context.canDuplicateDatabase = true
        #expect(enabled(#selector(MainSplitViewController.duplicateCurrentDatabase(_:)), context))
    }

    @Test("New Database needs a driver that switches containers")
    func createDatabaseNeedsContainerSupport() {
        var context = MenuValidationContext()
        context.isConnected = true
        #expect(!enabled(#selector(MainSplitViewController.createNewDatabase(_:)), context))
        context.canCreateDatabase = true
        #expect(enabled(#selector(MainSplitViewController.createNewDatabase(_:)), context))
    }
}

@MainActor
struct DatabaseMenuCommandTests {
    private func databaseMenu() -> NSMenu? {
        buildMenu().items.first { $0.title == String(localized: "Database") }?.submenu
    }

    @Test("Every command deferred from the first pass is present")
    func deferredCommandsArePresent() {
        let titles = (databaseMenu()?.items ?? []).map(\.title)
        for expected in [
            String(localized: "New Database…"),
            String(localized: "Show Table Structure"),
            String(localized: "Edit View Definition…"),
            String(localized: "Table Maintenance"),
            String(localized: "Favorite Database"),
            String(localized: "Disconnect"),
            String(localized: "Reconnect")
        ] {
            #expect(titles.contains(expected), "Database menu is missing \(expected)")
        }
    }

    @Test("Table Maintenance fills itself when the submenu opens")
    func maintenanceSubmenuIsDelegateDriven() {
        let container = databaseMenu()?.items.first { $0.title == String(localized: "Table Maintenance") }
        let submenu = container?.submenu
        #expect(submenu?.delegate != nil, "Driver-specific operations must be built on menuNeedsUpdate")
        #expect(submenu?.items.isEmpty == true, "The submenu is filled when it opens, not at build time")
    }

    /// The keyboard path to database favorites. The row star is hover-revealed and the context
    /// menus need a right-click, so without this menu the feature is pointer-only.
    @Test("Favorite Database fills itself when the submenu opens")
    func favoriteDatabaseSubmenuIsDelegateDriven() {
        let container = databaseMenu()?.items.first { $0.title == String(localized: "Favorite Database") }
        let submenu = container?.submenu
        #expect(submenu?.delegate != nil, "The current environment must be read on menuNeedsUpdate")
        #expect(submenu?.items.isEmpty == true, "The submenu is filled when it opens, not at build time")
    }

    @Test("Disconnect and Reconnect route through the responder chain")
    func connectionCommandsUseTheResponderChain() {
        let items = (databaseMenu()?.items ?? []).filter {
            $0.title == String(localized: "Disconnect") || $0.title == String(localized: "Reconnect")
        }
        #expect(items.count == 2)
        for item in items {
            #expect(item.target == nil)
        }
        #expect(items.first { $0.title == String(localized: "Disconnect") }?.action
            == #selector(MainSplitViewController.requestDisconnect))
        #expect(items.first { $0.title == String(localized: "Reconnect") }?.action
            == #selector(MainSplitViewController.retryConnection))
    }
}
