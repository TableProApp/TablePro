import AppKit
import Foundation
@testable import TablePro
import Testing

struct EditorBuiltInNameTests {
    @Test("Command-[ is Outdent and Command-] is Indent")
    func bracketsAreNamedAsTheEditorMapsThem() {
        #expect(
            ShortcutAction.reservedConflict(for: .character("[", command: true), context: .editor)
                == String(localized: "Outdent")
        )
        #expect(
            ShortcutAction.reservedConflict(for: .character("]", command: true), context: .editor)
                == String(localized: "Indent")
        )
    }
}

struct DefaultShortcutHygieneTests {
    // Control-1 switches Spaces, which is why the rule exists; Control-Tab is AppKit's own tab switching.
    private static let controlTabDefaults: Set<ShortcutAction> = [.switchToRecentTab, .switchToLeastRecentTab]

    @Test("No default uses Control without Command, apart from Control-Tab tab switching")
    func noBareControlDefaults() {
        for (action, key) in KeyboardSettings.defaultShortcuts where key.control && !key.command {
            if Self.controlTabDefaults.contains(action), key.keyCode == KeyCode.tab.rawValue, !key.option {
                continue
            }
            Issue.record("\(action.rawValue) uses Control without Command: \(key.displayString)")
        }
    }

    @Test("Recent tabs are Control-Tab and Control-Shift-Tab, and window tabs have no default")
    func recentTabDefaults() {
        #expect(KeyboardSettings.defaultShortcuts[.switchToRecentTab] == .special(.tab, control: true))
        #expect(KeyboardSettings.defaultShortcuts[.switchToLeastRecentTab] == .special(.tab, shift: true, control: true))
        #expect(KeyboardSettings.defaultShortcuts[.showPreviousWindowTab] == nil)
        #expect(KeyboardSettings.defaultShortcuts[.showNextWindowTab] == nil)
        #expect(ShortcutAction.switchToRecentTab.category == .navigation)
        #expect(ShortcutAction.switchToRecentTab.context == .global)
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

    @Test("Shift and Option text keys are reserved while text can have focus", arguments: [
        BoundKey.special(.delete, shift: true),
        .special(.forwardDelete, shift: true),
        .special(.space, shift: true),
        .special(.space, option: true),
        .special(.escape, option: true),
    ])
    func textInputKeysAreReserved(key: BoundKey) {
        #expect(ShortcutAction.reservedConflict(for: key, context: .editor) != nil)
        #expect(ShortcutAction.reservedConflict(for: key, context: .global) != nil)
        #expect(ShortcutAction.reservedConflict(for: key, context: .dataGrid) == nil)
        #expect(ShortcutAction.addRow.shadowsStandardTextEditingBinding(key))
    }

    @Test("Cmd+Delete does not conflict in data-grid context because focus resolves it")
    func commandDeleteDoesNotConflictInGrid() {
        let key = BoundKey.special(.delete, command: true)
        #expect(ShortcutAction.reservedConflict(for: key, context: .dataGrid) == nil)
    }

    // A disabled menu item still takes its key, so a binding here would starve the inspector's field shortcuts.
    @Test("Control-Option-N and D stay with the inspector, so no action can be bound to them")
    func inspectorStateChordsAreReserved() {
        let setNull = BoundKey.character("n", option: true, control: true)
        let setDefault = BoundKey.character("d", option: true, control: true)
        for context in [ShortcutContext.global, .editor, .dataGrid] {
            #expect(ShortcutAction.reservedConflict(for: setNull, context: context) == String(localized: "Set NULL"))
            #expect(
                ShortcutAction.reservedConflict(for: setDefault, context: context) == String(localized: "Set DEFAULT")
            )
        }
    }
}

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

struct BareKeyValidationTests {
    // Changed on purpose: nothing dispatches a bare key for Delete or Clear Selection.
    @Test("Only Preview FK Reference allows a bare key")
    func onlyPreviewFKReferenceAllowsBareKeys() {
        #expect(ShortcutAction.previewFKReference.allowsBareKey)
        #expect(!ShortcutAction.clearSelection.allowsBareKey)
        #expect(!ShortcutAction.delete.allowsBareKey)
        #expect(ShortcutAction.allCases.filter { $0.allowsBareKey } == [.previewFKReference])
    }

    @Test("Menu actions reject bare keys")
    func menuActionsRejectBareKeys() {
        #expect(!ShortcutAction.toggleInspector.allowsBareKey)
        #expect(!ShortcutAction.executeQuery.allowsBareKey)
    }

    // A letter with Option or Shift alone is typing, not a shortcut.
    @Test("Option and Shift cannot hold a shortcut without Command or Control")
    func optionAndShiftAloneAreNotRecordable() {
        func capture(_ flags: NSEvent.ModifierFlags) -> BoundKey? {
            let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "e",
                charactersIgnoringModifiers: "e",
                isARepeat: false,
                keyCode: 14
            )
            return event.flatMap(BoundKey.init(from:))
        }

        #expect(capture(.option) == nil)
        #expect(capture(.shift) == nil)
        #expect(capture([.option, .shift]) == nil)
        #expect(capture(.command) != nil)
        #expect(capture(.control) != nil)
        #expect(capture([.command, .option]) != nil)
    }

    @Test("hasModifier reflects the combo")
    func hasModifierReflectsCombo() {
        #expect(BoundKey.character("r", command: true).hasModifier)
        #expect(!BoundKey.special(.space).hasModifier)
    }

    @Test("Every bare-key default belongs to an action that allows bare keys")
    func bareKeyDefaultsAreAllowed() {
        for (action, key) in KeyboardSettings.defaultShortcuts where !key.hasModifier && !key.isFunctionKey {
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

    @Test("A key the focused grid reads conflicts with an editor binding, whose menu item would take it first")
    func gridReadKeyConflictsAcrossContexts() {
        let settings = KeyboardSettings.default
        #expect(settings.findConflict(for: .special(.return, command: true), excluding: .openValueEditor) == .executeQuery)
        #expect(settings.findConflict(for: .special(.return, option: true), excluding: .formatQuery) == .openValueEditor)
    }

    @Test("An editor action bound to the grid-read default stands that default down")
    func editorOverrideClaimsGridReadDefault() {
        let settings = KeyboardSettings(shortcuts: [ShortcutAction.formatQuery.rawValue: .special(.return, option: true)])
        #expect(settings.shortcut(for: .openValueEditor) == nil)
    }
}

struct KeyboardSettingsSanitizeTests {
    @Test("Bare-Space override on a menu action is dropped on load")
    func dropsBareSpaceMenuOverride() {
        let settings = KeyboardSettings(shortcuts: [ShortcutAction.toggleInspector.rawValue: .special(.space)])
        let sanitized = settings.sanitized()
        #expect(!sanitized.isCustomized(.toggleInspector))
        #expect(sanitized.shortcut(for: .toggleInspector) == KeyboardSettings.defaultShortcuts[.toggleInspector])
    }

    @Test("A bare-key override on Delete is dropped on load, since nothing dispatches it")
    func dropsBareDeleteOverride() {
        let settings = KeyboardSettings(shortcuts: [ShortcutAction.delete.rawValue: .special(.forwardDelete)])
        #expect(!settings.sanitized().isCustomized(.delete))
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

struct ShortcutAcceptanceTests {
    @Test("Command or Control makes any key bindable")
    func commandOrControlIsAccepted() {
        #expect(ShortcutAction.refresh.accepts(.character("e", command: true)))
        #expect(ShortcutAction.refresh.accepts(.character("e", control: true)))
    }

    @Test("A bare function key is accepted")
    func functionKeyIsAccepted() {
        #expect(ShortcutAction.refresh.accepts(BoundKey(keyCode: KeyCode.f5.rawValue)))
    }

    @Test("Option or Shift alone on a letter is refused")
    func optionLetterIsRefused() {
        #expect(!ShortcutAction.refresh.accepts(.character("e", option: true)))
        #expect(!ShortcutAction.refresh.accepts(.character("e", shift: true)))
        #expect(!ShortcutAction.refresh.accepts(.special(.return)))
    }

    @Test("A modified Delete, Escape or Space is accepted for a menu action")
    func modifiedBareRecordableKeyIsAccepted() {
        #expect(ShortcutAction.addRow.accepts(.special(.delete, option: true)))
        #expect(ShortcutAction.addRow.accepts(.special(.space, shift: true)))
        #expect(ShortcutAction.addRow.accepts(.special(.escape, option: true)))
    }

    @Test("A bare Space is accepted only for Preview FK Reference")
    func bareSpaceOnlyForPreview() {
        #expect(ShortcutAction.previewFKReference.accepts(.special(.space)))
        #expect(!ShortcutAction.delete.accepts(.special(.space)))
        #expect(!ShortcutAction.clearSelection.accepts(.special(.forwardDelete)))
    }

    @Test("An action's own default is always accepted")
    func ownDefaultIsAccepted() {
        for (action, key) in KeyboardSettings.defaultShortcuts {
            #expect(action.accepts(key), "\(action.rawValue) refuses its own default \(key.displayString)")
        }
    }

    @Test("Preview FK Reference explains that Space and function keys also work")
    func previewRefusalNamesItsExtraKeys() {
        #expect(ShortcutAction.previewFKReference.modifierRefusal == String(localized: "Use ⌘ or ⌃, Space, or a function key."))
        #expect(ShortcutAction.refresh.modifierRefusal == String(localized: "Add ⌘ or ⌃ to this shortcut."))
    }

    @Test("Capturing keeps the raw chord that BoundKey(from:) would refuse")
    func capturingKeepsRawChord() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option, .function],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "e",
            charactersIgnoringModifiers: "e",
            isARepeat: false,
            keyCode: KeyCode.e.rawValue
        ))
        #expect(BoundKey(from: event) == nil)
        #expect(BoundKey(capturing: event) == BoundKey(keyCode: KeyCode.e.rawValue, option: true))
    }
}

struct KeyboardSettingsEditingTests {
    private let modules: Set<AppModule> = []

    @Test("boundKey maps a cleared shortcut to nil")
    func boundKeyHidesCleared() {
        var settings = KeyboardSettings.default
        #expect(settings.boundKey(for: .refresh) == .character("r", command: true))
        settings.clearShortcut(for: .refresh)
        #expect(settings.shortcut(for: .refresh) == .cleared)
        #expect(settings.boundKey(for: .refresh) == nil)
    }

    @Test("Assigning a new key stores an override")
    func assigningStoresOverride() {
        let settings = KeyboardSettings.default.assigning(.character("j", command: true), to: .refresh)
        #expect(settings.shortcuts[ShortcutAction.refresh.rawValue] == .character("j", command: true))
    }

    @Test("Assigning the default again stores nothing")
    func assigningDefaultDropsOverride() {
        let custom = KeyboardSettings.default.assigning(.character("j", command: true), to: .refresh)
        let back = custom.assigning(.character("r", command: true), to: .refresh)
        #expect(!back.isCustomized(.refresh))
        #expect(back == .default)
    }

    @Test("Assigning the default keeps the override while another override claims it")
    func assigningClaimedDefaultKeepsOverride() {
        let claimed = KeyboardSettings(shortcuts: [ShortcutAction.executeQuery.rawValue: .character("r", command: true)])
        let settings = claimed.assigning(.character("r", command: true), to: .refresh)
        #expect(settings.isCustomized(.refresh))
    }

    @Test("Clearing an action with a default stores the cleared marker")
    func clearingWithDefault() {
        let settings = KeyboardSettings.default.clearing(.refresh)
        #expect(settings.shortcuts[ShortcutAction.refresh.rawValue] == .cleared)
        #expect(settings.boundKey(for: .refresh) == nil)
    }

    @Test("Clearing an action with no default removes its override")
    func clearingWithoutDefault() {
        let custom = KeyboardSettings.default.assigning(.character("j", command: true), to: .manageConnections)
        let settings = custom.clearing(.manageConnections)
        #expect(!settings.isCustomized(.manageConnections))
        #expect(settings.boundKey(for: .manageConnections) == nil)
    }

    @Test("Resetting removes the override")
    func resettingRestoresDefault() {
        let settings = KeyboardSettings.default.clearing(.refresh).resetting(.refresh)
        #expect(settings == .default)
    }

    @Test("The count leaves out entries for actions that no longer exist")
    func customizedCountSkipsUnknownEntries() {
        let settings = KeyboardSettings(shortcuts: [
            ShortcutAction.refresh.rawValue: .character("j", command: true),
            "future.unknown.action": .character("x", command: true),
        ])
        #expect(settings.customizedCount == 1)
        #expect(KeyboardSettings.default.customizedCount == 0)
    }

    @Test("Conflicts list every contending holder of the key")
    func conflictsListEveryHolder() {
        let key = BoundKey.character("j", command: true, option: true, control: true)
        let settings = KeyboardSettings(shortcuts: [
            ShortcutAction.formatQuery.rawValue: key,
            ShortcutAction.addRow.rawValue: key,
        ])
        #expect(settings.conflicts(for: key, excluding: .newTab, enabledModules: modules) == [.formatQuery, .addRow])
        #expect(settings.conflicts(for: key, excluding: .formatQuery, enabledModules: modules) == [])
    }

    @Test("Reassigning clears every customized holder in one value")
    func reassigningClearsCustomizedHolders() {
        let key = BoundKey.character("j", command: true, option: true, control: true)
        let settings = KeyboardSettings(shortcuts: [
            ShortcutAction.formatQuery.rawValue: key,
            ShortcutAction.addRow.rawValue: key,
        ])
        let next = settings.reassigning(key, to: .newTab, enabledModules: modules)
        #expect(next.boundKey(for: .newTab) == key)
        #expect(next.boundKey(for: .formatQuery) == nil)
        #expect(next.boundKey(for: .addRow) == nil)
        #expect(next.conflicts(for: key, excluding: .newTab, enabledModules: modules).isEmpty)
    }

    @Test("Reassigning leaves a holder on its default uncustomized, standing down")
    func reassigningStandsDownDefaultHolder() {
        let next = KeyboardSettings.default.reassigning(.character("r", command: true), to: .executeQuery, enabledModules: modules)
        #expect(next.boundKey(for: .executeQuery) == .character("r", command: true))
        #expect(!next.isCustomized(.refresh))
        #expect(next.boundKey(for: .refresh) == nil)
        #expect(next.defaultClaimant(for: .refresh) == .executeQuery)
    }

    @Test("A default nobody claimed has no claimant")
    func unclaimedDefaultHasNoClaimant() {
        #expect(KeyboardSettings.default.defaultClaimant(for: .refresh) == nil)
        #expect(KeyboardSettings.default.defaultClaimant(for: .manageConnections) == nil)
    }
}

struct KeyboardShortcutFilterTests {
    private let modules: Set<AppModule> = []

    private func actions(_ query: String, in settings: KeyboardSettings = .default) -> [ShortcutAction] {
        ShortcutAction.settingsSections(matching: query, in: settings, enabledModules: modules).flatMap { $0.actions }
    }

    @Test("An empty query lists every available action under its category")
    func emptyQueryListsEverything() {
        let sections = ShortcutAction.settingsSections(matching: "  ", in: .default, enabledModules: modules)
        let categories = sections.map { $0.category }
        let rows = sections.flatMap { $0.actions }
        #expect(categories == [.editor, .dataGrid, .navigation, .connections])
        #expect(rows.count == ShortcutAction.allCases.filter { $0.module == nil }.count)
    }

    @Test("Debug rows appear only while the Routine Debugger is on")
    func debugRowsFollowTheModule() {
        let on = ShortcutAction.settingsSections(matching: "", in: .default, enabledModules: [.routineDebugger])
        #expect(on.contains { $0.category == .debug })
    }

    @Test("Matching ignores case and diacritics")
    func matchingIsLocalizedStandard() {
        #expect(actions("refresh") == [.refresh])
        #expect(actions("RÉFRESH") == [.refresh])
    }

    @Test("Every term has to match, against the name or the category")
    func everyTermMustMatch() {
        #expect(actions("copy csv") == [.copyAsCsv, .copyAsCsvWithHeaders])
        #expect(actions("data grid refresh") == [.refresh])
        #expect(actions("refresh zzz").isEmpty)
    }

    @Test("A term with a modifier glyph also matches the bound key")
    func glyphTermMatchesKey() {
        #expect(actions("⌘R").contains(.refresh))
        let custom = KeyboardSettings.default.assigning(.character("k", command: true, option: true, control: true), to: .manageConnections)
        #expect(actions("⌃⌥⌘K", in: custom) == [.manageConnections])
    }

    @Test("A cleared key never matches a glyph term")
    func clearedKeyDoesNotMatch() {
        let cleared = KeyboardSettings.default.clearing(.refresh)
        #expect(!actions("⌘R", in: cleared).contains(.refresh))
    }

    @Test("No match leaves no sections")
    func noMatchLeavesNoSections() {
        #expect(ShortcutAction.settingsSections(matching: "zzzz", in: .default, enabledModules: modules).isEmpty)
    }
}
