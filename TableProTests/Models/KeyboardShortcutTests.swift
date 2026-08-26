//
//  KeyboardShortcutTests.swift
//  TableProTests
//
//  Pins the keyboard shortcut model: keyCode-based defaults, context-scoped
//  conflict detection, the built-in editor shortcut registry, bare-key handling,
//  and migration from the legacy character-string storage.
//

import Foundation
@testable import TablePro
import Testing

@Suite("ShortcutAction defaults")
struct ShortcutActionDefaultsTests {
    @Test("Execute Query default is Cmd+Return")
    func executeQueryDefault() {
        #expect(KeyboardSettings.defaultShortcuts[.executeQuery] == .special(.return, command: true))
    }

    @Test("Execute All Statements default is Cmd+Shift+Return")
    func executeAllStatementsDefault() {
        #expect(KeyboardSettings.defaultShortcuts[.executeAllStatements] == .special(.return, command: true, shift: true))
    }

    @Test("Cancel Query default is Cmd+.")
    func cancelQueryDefault() {
        #expect(KeyboardSettings.defaultShortcuts[.cancelQuery] == .character(".", command: true))
    }

    @Test("New Connection default is Cmd+N")
    func newConnectionDefault() {
        #expect(KeyboardSettings.defaultShortcuts[.newConnection] == .character("n", command: true))
    }

    @Test("First and Last Page have defaults")
    func paginationEdgeDefaults() {
        #expect(KeyboardSettings.defaultShortcuts[.firstPage] != nil)
        #expect(KeyboardSettings.defaultShortcuts[.lastPage] != nil)
    }

    @Test("Find Next and Find Previous have defaults")
    func findDefaults() {
        #expect(KeyboardSettings.defaultShortcuts[.findNext] == .character("g", command: true))
        #expect(KeyboardSettings.defaultShortcuts[.findPrevious] == .character("g", command: true, shift: true))
    }
}

@Suite("Default shortcut hygiene")
struct DefaultShortcutHygieneTests {
    @Test("No default uses Control without Command")
    func noBareControlDefaults() {
        for (action, key) in KeyboardSettings.defaultShortcuts where key.control && !key.command {
            Issue.record("\(action.rawValue) uses Control without Command: \(key.displayString)")
        }
    }

    @Test("No two defaults collide within overlapping contexts")
    func defaultsAreUniqueWithinContext() {
        let entries = Array(KeyboardSettings.defaultShortcuts)
        for outer in 0..<entries.count {
            for inner in (outer + 1)..<entries.count {
                let (actionA, keyA) = entries[outer]
                let (actionB, keyB) = entries[inner]
                guard keyA == keyB, actionA.context.overlaps(actionB.context) else { continue }
                Issue.record("\(actionA.rawValue) and \(actionB.rawValue) share \(keyA.displayString) in overlapping contexts")
            }
        }
    }
}

@Suite("Reserved shortcuts")
struct ReservedShortcutTests {
    @Test("Cmd+[ conflicts with the editor indent command in editor context")
    func bracketConflictsInEditor() {
        let key = BoundKey.character("[", command: true)
        #expect(ShortcutAction.reservedConflict(for: key, context: .editor) != nil)
    }

    @Test("Cmd+[ does not conflict in data-grid context")
    func bracketDoesNotConflictInGrid() {
        let key = BoundKey.character("[", command: true)
        #expect(ShortcutAction.reservedConflict(for: key, context: .dataGrid) == nil)
    }

    @Test("Cmd+5 is reserved for tab selection in every context")
    func tabSelectionIsReserved() {
        let key = BoundKey.character("5", command: true)
        #expect(ShortcutAction.reservedConflict(for: key, context: .dataGrid) != nil)
        #expect(ShortcutAction.reservedConflict(for: key, context: .editor) != nil)
    }

    @Test("Cmd+= is reserved for zoom")
    func zoomIsReserved() {
        #expect(ShortcutAction.reservedConflict(for: .character("=", command: true), context: .global) != nil)
    }

    @Test("No default shadows a reserved app or editor command")
    func defaultsAvoidReservedShortcuts() {
        for (action, key) in KeyboardSettings.defaultShortcuts {
            if let name = ShortcutAction.reservedConflict(for: key, context: action.context) {
                Issue.record("\(action.rawValue) default \(key.displayString) is reserved for \(name)")
            }
        }
    }

    @Test("Cmd+Delete conflicts with the system delete-to-line-start binding in editor context")
    func commandDeleteConflictsInEditor() {
        let key = BoundKey.special(.delete, command: true)
        #expect(ShortcutAction.reservedConflict(for: key, context: .editor) != nil)
    }

    @Test("Option+Delete conflicts with the system delete-word binding in global context")
    func optionDeleteConflictsGlobally() {
        let key = BoundKey.special(.delete, option: true)
        #expect(ShortcutAction.reservedConflict(for: key, context: .global) != nil)
    }

    @Test("Cmd+Delete does not conflict in data-grid context because focus resolves it")
    func commandDeleteDoesNotConflictInGrid() {
        let key = BoundKey.special(.delete, command: true)
        #expect(ShortcutAction.reservedConflict(for: key, context: .dataGrid) == nil)
    }
}

@Suite("Standard text-editing bindings")
struct StandardTextEditingBindingTests {
    @Test("Delete shadows the system delete-to-line-start binding")
    func deleteShadowsCommandDelete() {
        #expect(ShortcutAction.delete.shadowsStandardTextEditingBinding(.special(.delete, command: true)))
    }

    @Test("Truncate Table shadows the system delete-word binding")
    func truncateShadowsOptionDelete() {
        #expect(ShortcutAction.truncateTable.shadowsStandardTextEditingBinding(.special(.delete, option: true)))
    }

    @Test("A grid action bound to a bare key shadows nothing")
    func bareKeyShadowsNothing() {
        #expect(!ShortcutAction.delete.shadowsStandardTextEditingBinding(.special(.delete)))
    }

    @Test("A grid action with no colliding binding shadows nothing")
    func nonCollidingGridActionShadowsNothing() {
        #expect(!ShortcutAction.addRow.shadowsStandardTextEditingBinding(.character("n", command: true, shift: true)))
    }

    @Test("An editor action keeps its shortcut even on a colliding key")
    func editorActionNeverShadows() {
        #expect(!ShortcutAction.executeQuery.shadowsStandardTextEditingBinding(.special(.delete, command: true)))
    }

    @Test("A missing or cleared binding shadows nothing")
    func missingBindingShadowsNothing() {
        #expect(!ShortcutAction.delete.shadowsStandardTextEditingBinding(nil))
        #expect(!ShortcutAction.delete.shadowsStandardTextEditingBinding(.cleared))
    }

    @Test("Only Delete and Truncate Table shadow a system binding by default")
    func defaultsThatShadow() {
        let shadowing = KeyboardSettings.defaultShortcuts
            .filter { $0.key.shadowsStandardTextEditingBinding($0.value) }
            .map(\.key.rawValue)
            .sorted()
        #expect(shadowing == [ShortcutAction.delete.rawValue, ShortcutAction.truncateTable.rawValue].sorted())
    }
}

@Suite("Bare-key validation")
struct BareKeyValidationTests {
    @Test("Grid actions allow bare keys")
    func gridActionsAllowBareKeys() {
        #expect(ShortcutAction.previewFKReference.allowsBareKey)
        #expect(ShortcutAction.clearSelection.allowsBareKey)
        #expect(ShortcutAction.delete.allowsBareKey)
    }

    @Test("Menu actions reject bare keys")
    func menuActionsRejectBareKeys() {
        #expect(!ShortcutAction.toggleInspector.allowsBareKey)
        #expect(!ShortcutAction.executeQuery.allowsBareKey)
    }

    @Test("hasModifier reflects the combo")
    func hasModifierReflectsCombo() {
        #expect(BoundKey.character("r", command: true).hasModifier)
        #expect(!BoundKey.special(.space).hasModifier)
    }

    @Test("Every bare-key default belongs to an action that allows bare keys")
    func bareKeyDefaultsAreAllowed() {
        for (action, key) in KeyboardSettings.defaultShortcuts where !key.hasModifier {
            #expect(action.allowsBareKey, "\(action.rawValue) ships a bare-key default but does not allow bare keys")
        }
    }

    @Test("Bare-key actions never register a global menu key-equivalent")
    func bareKeysNotRegisteredInMenu() {
        let settings = KeyboardSettings.default
        #expect(settings.keyboardShortcut(for: .previewFKReference) == nil)
        #expect(settings.keyboardShortcut(for: .clearSelection) == nil)
    }

    @Test("A modifier action registers a menu key-equivalent")
    func modifierActionRegistersInMenu() {
        #expect(KeyboardSettings.default.keyboardShortcut(for: .saveChanges) != nil)
    }

    @Test("A bare function-key binding registers and survives sanitization")
    func functionKeyRegistersInMenu() {
        let settings = KeyboardSettings(shortcuts: [ShortcutAction.refresh.rawValue: BoundKey(keyCode: KeyCode.f5.rawValue)])
        #expect(settings.keyboardShortcut(for: .refresh) != nil)
        #expect(settings.sanitized().shortcut(for: .refresh)?.isFunctionKey == true)
    }
}

@Suite("Shortcut conflict detection")
struct ShortcutConflictTests {
    @Test("Assigning Cmd+R to Execute Query conflicts with Refresh")
    func cmdRConflictsWithRefresh() {
        let settings = KeyboardSettings.default
        let conflict = settings.findConflict(for: .character("r", command: true), excluding: .executeQuery)
        #expect(conflict == .refresh)
    }

    @Test("Cmd+F is held by the global Find action, so an editor binding collides with it")
    func commandFConflictsWithFind() {
        let settings = KeyboardSettings.default
        let conflict = settings.findConflict(for: .character("f", command: true), excluding: .executeQuery)
        #expect(conflict == .find)
    }

    @Test("A data-grid binding does not conflict with an editor-only default")
    func crossContextDoesNotConflict() {
        let settings = KeyboardSettings.default
        #expect(KeyboardSettings.defaultShortcuts[.formatQuery] == .character("l", command: true, shift: true))
        let conflict = settings.findConflict(
            for: .character("l", command: true, shift: true),
            excluding: .previousPage
        )
        #expect(conflict == nil)
    }
}

@Suite("Keyboard settings sanitization")
struct KeyboardSettingsSanitizeTests {
    @Test("Bare-Space override on a menu action is dropped on load")
    func dropsBareSpaceMenuOverride() {
        let settings = KeyboardSettings(shortcuts: [ShortcutAction.toggleInspector.rawValue: .special(.space)])
        let sanitized = settings.sanitized()
        #expect(!sanitized.isCustomized(.toggleInspector))
        #expect(sanitized.shortcut(for: .toggleInspector) == KeyboardSettings.defaultShortcuts[.toggleInspector])
    }

    @Test("Bare-key override on a grid action survives")
    func keepsBareKeyGridOverride() {
        let space = BoundKey.special(.space)
        let settings = KeyboardSettings(shortcuts: [ShortcutAction.previewFKReference.rawValue: space])
        #expect(settings.sanitized().shortcut(for: .previewFKReference) == space)
    }

    @Test("Cleared sentinel survives")
    func keepsClearedSentinel() {
        let settings = KeyboardSettings(shortcuts: [ShortcutAction.executeQuery.rawValue: .cleared])
        let sanitized = settings.sanitized()
        #expect(sanitized.isCustomized(.executeQuery))
        #expect(sanitized.keyboardShortcut(for: .executeQuery) == nil)
    }

    @Test("Modifier override survives")
    func keepsModifierOverride() {
        let key = BoundKey.character("r", command: true, shift: true)
        let settings = KeyboardSettings(shortcuts: [ShortcutAction.toggleInspector.rawValue: key])
        #expect(settings.sanitized().shortcut(for: .toggleInspector) == key)
    }

    @Test("Unknown action raw value survives sanitization")
    func keepsUnknownRawValue() {
        let key = BoundKey.character("x", command: true)
        let settings = KeyboardSettings(shortcuts: ["future.unknown.action": key])
        #expect(settings.sanitized().shortcuts["future.unknown.action"] == key)
    }
}

@Suite("Workspace navigation defaults")
struct WorkspaceNavigationShortcutTests {
    @Test("Moving through the rail is bound to Control-Command and the arrow that matches the direction")
    func workspaceCyclingIsBoundToVerticalArrows() {
        let settings = KeyboardSettings.default
        #expect(settings.shortcut(for: .showPreviousWorkspace) == .special(.upArrow, command: true, control: true))
        #expect(settings.shortcut(for: .showNextWorkspace) == .special(.downArrow, command: true, control: true))
    }

    @Test("A chord the user already spent stands down the default that would fight it")
    func aClaimedChordDisarmsTheNewDefault() {
        var settings = KeyboardSettings.default
        settings.setShortcut(.special(.upArrow, command: true, control: true), for: .firstPage)

        #expect(settings.shortcut(for: .firstPage) == .special(.upArrow, command: true, control: true))
        #expect(settings.shortcut(for: .showPreviousWorkspace) == nil)
    }

    @Test("Standing a default down leaves every other default alone")
    func disarmingOneDefaultSparesTheRest() {
        var settings = KeyboardSettings.default
        settings.setShortcut(.special(.upArrow, command: true, control: true), for: .firstPage)

        #expect(settings.shortcut(for: .showNextWorkspace) == .special(.downArrow, command: true, control: true))
        #expect(settings.shortcut(for: .toggleWorkspaceRail) == .character("0", command: true, option: true))
    }

    @Test("Releasing the conflicting chord re-arms the default on its own")
    func releasingTheClaimRestoresTheDefault() {
        var settings = KeyboardSettings.default
        settings.setShortcut(.special(.upArrow, command: true, control: true), for: .firstPage)
        #expect(settings.shortcut(for: .showPreviousWorkspace) == nil)

        settings.resetToDefault(for: .firstPage)
        #expect(settings.shortcut(for: .showPreviousWorkspace) == .special(.upArrow, command: true, control: true))
    }

    @Test("Standing a default down never counts as the user customizing it")
    func yieldingDoesNotMarkTheActionCustomized() {
        var settings = KeyboardSettings.default
        settings.setShortcut(.special(.upArrow, command: true, control: true), for: .firstPage)

        #expect(!settings.isCustomized(.showPreviousWorkspace))
        #expect(settings.sanitized().shortcuts[ShortcutAction.showPreviousWorkspace.rawValue] == nil)
    }

    @Test("An untouched settings file keeps every default")
    func defaultsSurviveSanitizationUntouched() {
        let sanitized = KeyboardSettings.default.sanitized()
        for (action, key) in KeyboardSettings.defaultShortcuts {
            #expect(sanitized.shortcut(for: action) == key)
        }
    }
}

@Suite("Legacy migration")
struct KeyboardSettingsMigrationTests {
    private func decode(_ json: String) throws -> KeyboardSettings {
        try JSONDecoder().decode(KeyboardSettings.self, from: Data(json.utf8))
    }

    @Test("Legacy character shortcut migrates to its key code")
    func migratesCharacterShortcut() throws {
        let json = """
        {"shortcuts":{"saveChanges":{"key":"s","command":true,"shift":false,"option":false,"control":false,"isSpecialKey":false}}}
        """
        let settings = try decode(json)
        #expect(settings.shortcut(for: .saveChanges) == .character("s", command: true))
    }

    @Test("Legacy special shortcut migrates to its key code")
    func migratesSpecialShortcut() throws {
        let json = """
        {"shortcuts":{"executeQuery":{"key":"return","command":true,"shift":false,"option":false,"control":false,"isSpecialKey":true}}}
        """
        let settings = try decode(json)
        #expect(settings.shortcut(for: .executeQuery) == .special(.return, command: true))
    }

    @Test("Modern keyCode shortcut decodes unchanged")
    func decodesModernShortcut() throws {
        let original = KeyboardSettings(shortcuts: [ShortcutAction.toggleHistory.rawValue: .character("y", command: true, shift: true)])
        let data = try JSONEncoder().encode(original)
        let roundTripped = try JSONDecoder().decode(KeyboardSettings.self, from: data)
        #expect(roundTripped == original)
    }

    @Test("Legacy cleared shortcut migrates to the cleared sentinel")
    func migratesClearedShortcut() throws {
        let json = """
        {"shortcuts":{"executeQuery":{"key":"","command":false,"shift":false,"option":false,"control":false,"isSpecialKey":false}}}
        """
        let settings = try decode(json)
        #expect(settings.shortcut(for: .executeQuery)?.isCleared == true)
    }
}

@Suite("Shortcut hint")
struct ShortcutHintTests {
    @Test("Switch Connection default hint shows Control+Command+C")
    func switchConnectionDefaultHint() {
        let hint = KeyboardSettings.default.shortcutHint(
            String(localized: "Switch Connection"),
            for: .switchConnection
        )
        #expect(hint == "Switch Connection (⌃⌘C)")
    }

    @Test("Hint reflects a user override")
    func hintReflectsOverride() {
        var settings = KeyboardSettings.default
        settings.setShortcut(.character("j", command: true), for: .switchConnection)
        let hint = settings.shortcutHint(String(localized: "Switch Connection"), for: .switchConnection)
        #expect(hint == "Switch Connection (⌘J)")
    }

    @Test("Cleared shortcut shows label only")
    func clearedShortcutShowsLabelOnly() {
        var settings = KeyboardSettings.default
        settings.clearShortcut(for: .switchConnection)
        let hint = settings.shortcutHint(String(localized: "Switch Connection"), for: .switchConnection)
        #expect(hint == "Switch Connection")
    }

    @Test("Action without a default shows label only")
    func unsetShortcutShowsLabelOnly() {
        let hint = KeyboardSettings.default.shortcutHint(
            String(localized: "Manage Connections"),
            for: .manageConnections
        )
        #expect(hint == "Manage Connections")
    }
}
