//
//  KeyboardShortcutTests.swift
//  TableProTests
//
//  Pins the shortcut customization fixes for #1357: Execute Query / Cancel Query
//  are customizable, bare keys are rejected for menu-driven actions, and stale
//  bare-key overrides self-heal on load.
//

import Foundation
@testable import TablePro
import Testing

@Suite("ShortcutAction defaults")
struct ShortcutActionDefaultsTests {
    @Test("Execute Query default is Cmd+Return")
    func executeQueryDefault() {
        #expect(KeyboardSettings.defaultShortcuts[.executeQuery] == KeyCombo(key: "return", command: true, isSpecialKey: true))
    }

    @Test("Execute All Statements default is Cmd+Shift+Return")
    func executeAllStatementsDefault() {
        #expect(
            KeyboardSettings.defaultShortcuts[.executeAllStatements]
                == KeyCombo(key: "return", command: true, shift: true, isSpecialKey: true)
        )
    }

    @Test("Cancel Query default is Cmd+.")
    func cancelQueryDefault() {
        #expect(KeyboardSettings.defaultShortcuts[.cancelQuery] == KeyCombo(key: ".", command: true))
    }

    @Test("Save as Favorite default is Cmd+D")
    func saveAsFavoriteDefault() {
        #expect(KeyboardSettings.defaultShortcuts[.saveAsFavorite] == KeyCombo(key: "d", command: true))
    }
}

@Suite("System reserved shortcuts")
struct SystemReservedShortcutTests {
    @Test("Ctrl+Cmd+D is reserved by macOS for Look Up")
    func ctrlCmdDIsReserved() {
        #expect(KeyCombo(key: "d", command: true, control: true).isSystemReserved)
    }

    @Test("No default shortcut collides with a system-reserved combo")
    func defaultsAvoidSystemReserved() {
        for (action, combo) in KeyboardSettings.defaultShortcuts {
            #expect(!combo.isSystemReserved, "\(action.rawValue) ships a system-reserved default: \(combo.displayString)")
        }
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
        #expect(KeyCombo(key: "r", command: true).hasModifier)
        #expect(!KeyCombo(key: "space", isSpecialKey: true).hasModifier)
    }

    @Test("Every bare-key default belongs to an action that allows bare keys")
    func bareKeyDefaultsAreAllowed() {
        for (action, combo) in KeyboardSettings.defaultShortcuts where !combo.hasModifier {
            #expect(action.allowsBareKey, "\(action.rawValue) ships a bare-key default but does not allow bare keys")
        }
    }
}

@Suite("Shortcut conflict detection")
struct ShortcutConflictTests {
    @Test("Assigning Cmd+R to Execute Query conflicts with Refresh")
    func cmdRConflictsWithRefresh() {
        let settings = KeyboardSettings.default
        let conflict = settings.findConflict(for: KeyCombo(key: "r", command: true), excluding: .executeQuery)
        #expect(conflict == .refresh)
    }
}

@Suite("Keyboard settings sanitization")
struct KeyboardSettingsSanitizeTests {
    @Test("Bare-Space override on a menu action is dropped on load")
    func dropsBareSpaceMenuOverride() {
        let settings = KeyboardSettings(shortcuts: [
            ShortcutAction.toggleInspector.rawValue: KeyCombo(key: "space", isSpecialKey: true)
        ])
        let sanitized = settings.sanitized()
        #expect(!sanitized.isCustomized(.toggleInspector))
        #expect(sanitized.shortcut(for: .toggleInspector) == KeyboardSettings.defaultShortcuts[.toggleInspector])
    }

    @Test("Bare-key override on a grid action survives")
    func keepsBareKeyGridOverride() {
        let space = KeyCombo(key: "space", isSpecialKey: true)
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
        let combo = KeyCombo(key: "r", command: true, shift: true)
        let settings = KeyboardSettings(shortcuts: [ShortcutAction.toggleInspector.rawValue: combo])
        #expect(settings.sanitized().shortcut(for: .toggleInspector) == combo)
    }

    @Test("Unknown action raw value survives sanitization")
    func keepsUnknownRawValue() {
        let combo = KeyCombo(key: "x", command: true)
        let settings = KeyboardSettings(shortcuts: ["future.unknown.action": combo])
        #expect(settings.sanitized().shortcuts["future.unknown.action"] == combo)
    }
}
