import Foundation
@testable import TablePro
import Testing

private enum KeymapFixtures {
    // The file every app reads lives in the Rust core, four folders above this one.
    static let repoFileURL: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 {
            url = url.deletingLastPathComponent()
        }
        return url.appendingPathComponent("core/crates/core/keymaps.json")
    }()

    static func repoCatalog() throws -> KeyboardPresetCatalog {
        try KeyboardPresetCatalog.load(from: repoFileURL)
    }

    static func catalog(_ json: String) throws -> KeyboardPresetCatalog {
        try KeyboardPresetCatalog.decode(Data(json.utf8))
    }

    static func noHotkeys(_ key: BoundKey) -> Bool {
        false
    }

    static func usLayout(_ character: Character) -> UInt16? {
        (UInt16(0)...127).lazy.compactMap { KeyCode(rawValue: $0) }.first { $0.usBaseCharacter == character }?.rawValue
    }

    // French AZERTY moves A, Q, Z, W and M; every other key keeps its US position here.
    static func azertyLayout(_ character: Character) -> UInt16? {
        let moved: [Character: KeyCode] = ["a": .q, "q": .a, "z": .w, "w": .z, "m": .semicolon]
        if let key = moved[character] { return key.rawValue }
        return usLayout(character)
    }

    static func displaced(in settings: KeyboardSettings) -> [String: String] {
        var result: [String: String] = [:]
        for action in ShortcutAction.allCases {
            if let claimant = settings.defaultClaimant(for: action) {
                result[action.rawValue] = claimant.rawValue
            }
        }
        return result
    }
}

struct KeyboardPresetCatalogTests {
    @Test("The repository keymap file decodes")
    func repoFileDecodes() throws {
        let catalog = try KeymapFixtures.repoCatalog()
        #expect(!catalog.presets.isEmpty)
    }

    @Test("Every action is a macOS action or one listed as having no macOS case")
    func everyActionIsKnown() throws {
        for preset in try KeymapFixtures.repoCatalog().presets {
            for binding in preset.bindings {
                let known = ShortcutAction(rawValue: binding.action) != nil
                    || KeyboardPreset.actionsWithoutMacCase.contains(binding.action)
                #expect(known, "\(preset.id) binds unknown action \(binding.action)")
            }
        }
    }

    @Test("Every chord in the file parses")
    func everyChordParses() throws {
        for preset in try KeymapFixtures.repoCatalog().presets {
            for binding in preset.bindings {
                for text in [binding.key, binding.mac, binding.linux, binding.windows].compactMap({ $0 }) {
                    #expect(PresetChord(text) != nil, "\(preset.id) \(binding.action): \(text)")
                }
            }
        }
    }

    @Test("Preset ids are unique")
    func idsAreUnique() throws {
        let ids = try KeymapFixtures.repoCatalog().presets.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Another schema version is refused")
    func refusesOtherSchema() {
        #expect(throws: DecodingError.self) {
            try KeymapFixtures.catalog(#"{ "schemaVersion": 2, "presets": [] }"#)
        }
    }

    @Test("A binding without derived reads as not derived")
    func derivedDefaultsToFalse() throws {
        let catalog = try KeymapFixtures.catalog("""
        { "schemaVersion": 1, "presets": [ { "id": "second", "name": "Second", "platforms": ["macos"],
          "bindings": [ { "action": "formatQuery", "key": "ctrl+shift+f" } ] } ] }
        """)
        #expect(catalog.presets.first?.bindings.first?.derived == false)
    }

    @Test("The imported app's preset is listed first and the rest keep the file order")
    func listingPutsImportedAppFirst() throws {
        let catalog = try KeymapFixtures.catalog("""
        { "schemaVersion": 1, "presets": [
          { "id": "first", "name": "First", "platforms": ["macos"], "bindings": [] },
          { "id": "second", "name": "Second", "platforms": ["macos"], "bindings": [] },
          { "id": "third", "name": "Third", "platforms": ["macos"], "bindings": [] } ] }
        """)
        #expect(catalog.listing(first: "third").map { $0.id } == ["third", "first", "second"])
        #expect(catalog.listing(first: nil).map { $0.id } == ["first", "second", "third"])
        #expect(catalog.listing(first: "unknown").map { $0.id } == ["first", "second", "third"])
    }

    @Test("A preset that does not list macOS is not offered on the Mac")
    func listingSkipsOtherPlatforms() throws {
        let catalog = try KeymapFixtures.catalog("""
        { "schemaVersion": 1, "presets": [
          { "id": "fourth", "name": "Fourth", "platforms": ["linux", "windows"], "bindings": [] },
          { "id": "second", "name": "Second", "platforms": ["macos", "linux"], "bindings": [] } ] }
        """)
        #expect(catalog.listing(first: "fourth").map { $0.id } == ["second"])
    }
}

struct PresetChordTests {
    @Test("Modifiers parse in any order")
    func modifiersInAnyOrder() {
        let chord = PresetChord("cmd+shift+l")
        #expect(chord == PresetChord("shift+cmd+l"))
        #expect(chord?.command == true)
        #expect(chord?.shift == true)
        #expect(chord?.control == false)
        #expect(chord?.option == false)
        #expect(chord?.key == "l")
    }

    @Test("Malformed chords are refused", arguments: ["", "cmd", "cmd+", "+l", "cmd+cmd+l", "hyper+l", "cmd+enterx", "cmd+L"])
    func malformedRefused(text: String) {
        #expect(PresetChord(text) == nil)
    }

    @Test("Enter is Return, never the keypad Enter")
    func enterIsReturn() {
        #expect(PresetChord("cmd+enter")?.boundKey == .special(.return, command: true))
    }

    @Test("Backspace is the Delete key and delete is Forward Delete")
    func deleteNames() {
        #expect(PresetChord("alt+backspace")?.boundKey == .special(.delete, option: true))
        #expect(PresetChord("alt+delete")?.boundKey == .special(.forwardDelete, option: true))
    }

    @Test("ctrl is Control and alt is Option")
    func modifierMapping() {
        #expect(PresetChord("ctrl+alt+shift+t")?.boundKey == .character("t", shift: true, option: true, control: true))
    }

    @Test("Named keys and F-keys resolve to their key codes")
    func namedKeys() {
        #expect(PresetChord("f5")?.boundKey == .special(.f5))
        #expect(PresetChord("ctrl+pagedown")?.boundKey == .special(.pageDown, control: true))
        #expect(PresetChord("ctrl+tab")?.boundKey == .special(.tab, control: true))
        #expect(PresetChord("cmd+-")?.boundKey == .character("-", command: true))
    }

    @Test("A key a Mac keyboard does not have resolves to nothing", arguments: ["alt+insert", "cmd+f13"])
    func keysWithoutAMacKey(text: String) {
        #expect(PresetChord(text) != nil)
        #expect(PresetChord(text)?.boundKey == nil)
    }

    @Test("A character resolves on the layout it is given")
    func characterFollowsLayout() {
        let chord = PresetChord("cmd+a")
        #expect(chord?.boundKey(keyCode: KeymapFixtures.usLayout)?.keyCode == KeyCode.a.rawValue)
        #expect(chord?.boundKey(keyCode: KeymapFixtures.azertyLayout)?.keyCode == KeyCode.q.rawValue)
    }
}

struct KeyboardPresetApplyTests {
    private static let sample = """
    { "schemaVersion": 1, "presets": [
      { "id": "first", "name": "First", "platforms": ["macos", "linux", "windows"], "bindings": [
        { "action": "newTab", "key": "ctrl+e", "mac": "cmd+e", "derived": true },
        { "action": "executeQuery", "key": "ctrl+enter", "mac": "cmd+enter", "derived": true },
        { "action": "showNextTab", "key": "ctrl+]", "mac": "cmd+]", "derived": true },
        { "action": "newConnection", "linux": "ctrl+shift+k" },
        { "action": "discardChanges", "key": "ctrl+shift+backspace", "mac": "shift+cmd+backspace", "derived": true },
        { "action": "toggleHistory", "mac": "alt+cmd+q" }
      ] },
      { "id": "second", "name": "Second", "platforms": ["macos"], "bindings": [
        { "action": "newTab", "mac": "cmd+e" }
      ] }
    ] }
    """

    private func preset(_ id: String) throws -> KeyboardPreset {
        try #require(try KeymapFixtures.catalog(Self.sample).presets.first { $0.id == id })
    }

    @Test("A row that differs from its default becomes an override, and its displaced default yields")
    func differingRowOverrides() throws {
        let settings = KeyboardSettings.default.applying(try preset("first"), isSystemHotkey: KeymapFixtures.noHotkeys)

        #expect(settings.shortcut(for: .newTab) == .character("e", command: true))
        #expect(settings.shortcut(for: .useSelectionForFind) == nil)
        #expect(!settings.isCustomized(.useSelectionForFind))
        #expect(settings.shortcuts[ShortcutAction.useSelectionForFind.rawValue] == nil)
    }

    @Test("A row equal to its default writes nothing")
    func defaultRowWritesNothing() throws {
        let settings = KeyboardSettings.default.applying(try preset("first"), isSystemHotkey: KeymapFixtures.noHotkeys)
        #expect(!settings.isCustomized(.executeQuery))
    }

    @Test("A row on a reserved key is dropped and the command keeps its default")
    func reservedRowDropped() throws {
        let settings = KeyboardSettings.default.applying(try preset("first"), isSystemHotkey: KeymapFixtures.noHotkeys)
        #expect(!settings.isCustomized(.showNextTab))
        #expect(settings.shortcut(for: .showNextTab) == KeyboardSettings.defaultShortcuts[.showNextTab])
    }

    @Test("Rows with no macOS chord or no macOS action are left out")
    func otherPlatformRowsLeftOut() throws {
        let settings = KeyboardSettings.default.applying(try preset("first"), isSystemHotkey: KeymapFixtures.noHotkeys)
        #expect(!settings.isCustomized(.newConnection))
        #expect(settings.shortcuts["discardChanges"] == nil)
    }

    @Test("A row on a system hotkey is left out")
    func systemHotkeyRowLeftOut() throws {
        let hotkey = BoundKey.character("q", command: true, option: true)
        let settings = KeyboardSettings.default.applying(try preset("first"), isSystemHotkey: { $0 == hotkey })
        #expect(!settings.isCustomized(.toggleHistory))
        #expect(settings.isCustomized(.newTab))
    }

    @Test("Applying writes no cleared marker")
    func noClears() throws {
        let settings = KeyboardSettings.default.applying(try preset("first"), isSystemHotkey: KeymapFixtures.noHotkeys)
        #expect(!settings.shortcuts.values.contains { $0.isCleared })
    }

    @Test("Customized means at least one known action has an override")
    func customizedFollowsOverrides() {
        #expect(!KeyboardSettings.default.isCustomized)
        #expect(!KeyboardSettings(shortcuts: ["future.action": .character("x", command: true)]).isCustomized)
        #expect(KeyboardSettings(shortcuts: [ShortcutAction.refresh.rawValue: .special(.f5)]).isCustomized)
    }
}

struct KeyboardAppliedPresetTests {
    private static let sample = """
    { "schemaVersion": 1, "presets": [
      { "id": "first", "name": "First", "platforms": ["macos"], "bindings": [
        { "action": "newTab", "mac": "cmd+e" },
        { "action": "toggleHistory", "mac": "alt+cmd+a" },
        { "action": "quickSwitcher", "mac": "cmd+p" }
      ] },
      { "id": "second", "name": "Second", "platforms": ["macos"], "bindings": [
        { "action": "newTab", "mac": "cmd+e" }
      ] },
      { "id": "third", "name": "Third", "platforms": ["macos"], "bindings": [
        { "action": "newTab", "mac": "cmd+y" },
        { "action": "toggleHistory", "mac": "shift+cmd+h" }
      ] }
    ] }
    """

    private func catalog() throws -> KeyboardPresetCatalog {
        try KeymapFixtures.catalog(Self.sample)
    }

    @Test("Settings with no override match no preset")
    func defaultsMatchNothing() throws {
        let catalog = try catalog()
        #expect(KeyboardSettings.default.appliedPreset(in: catalog) == nil)
    }

    @Test("Each preset reads back as itself on the layout it was applied on", arguments: ["us", "azerty"])
    func roundTripOnEachLayout(layoutName: String) throws {
        let layout: (Character) -> UInt16? = { character in
            layoutName == "us" ? KeymapFixtures.usLayout(character) : KeymapFixtures.azertyLayout(character)
        }
        let catalog = try catalog()
        for preset in catalog.presets {
            let settings = KeyboardSettings.default.applying(preset, isSystemHotkey: KeymapFixtures.noHotkeys, keyCode: layout)
            #expect(settings.appliedPreset(in: catalog, keyCode: layout) == preset.id, "\(preset.id) on \(layoutName)")
        }
    }

    @Test("The two layouts write different keys for a letter that moves")
    func layoutsDiffer() throws {
        let preset = try #require(try catalog().presets.first { $0.id == "first" })
        let us = KeyboardSettings.default.applying(preset, isSystemHotkey: KeymapFixtures.noHotkeys, keyCode: KeymapFixtures.usLayout)
        let azerty = KeyboardSettings.default.applying(preset, isSystemHotkey: KeymapFixtures.noHotkeys, keyCode: KeymapFixtures.azertyLayout)
        #expect(us.shortcuts[ShortcutAction.toggleHistory.rawValue] != azerty.shortcuts[ShortcutAction.toggleHistory.rawValue])
    }

    @Test("A row a system hotkey kept out still reads as the preset")
    func hotkeyGapStillMatches() throws {
        let catalog = try catalog()
        let preset = try #require(catalog.presets.first { $0.id == "first" })
        let hotkey = BoundKey.character("p", command: true)
        let settings = KeyboardSettings.default.applying(preset, isSystemHotkey: { $0 == hotkey })

        #expect(!settings.isCustomized(.quickSwitcher))
        #expect(settings.appliedPreset(in: catalog) == "first")
    }

    @Test("When several presets hold every override, the one with the fewest missing rows wins")
    func closestPresetWins() throws {
        let catalog = try catalog()
        let second = try #require(catalog.presets.first { $0.id == "second" })
        let settings = KeyboardSettings.default.applying(second, isSystemHotkey: KeymapFixtures.noHotkeys)
        #expect(settings.appliedPreset(in: catalog) == "second")
    }

    @Test("An override the preset does not have reads as custom")
    func extraOverrideIsCustom() throws {
        let catalog = try catalog()
        let preset = try #require(catalog.presets.first { $0.id == "third" })
        var settings = KeyboardSettings.default.applying(preset, isSystemHotkey: KeymapFixtures.noHotkeys)
        settings.setShortcut(.special(.f5), for: .refresh)
        #expect(settings.appliedPreset(in: catalog) == nil)
    }

    @Test("A cleared shortcut reads as custom")
    func clearedIsCustom() throws {
        let catalog = try catalog()
        let preset = try #require(catalog.presets.first { $0.id == "third" })
        let settings = KeyboardSettings.default.applying(preset, isSystemHotkey: KeymapFixtures.noHotkeys).clearing(.newTab)
        #expect(settings.appliedPreset(in: catalog) == nil)
    }
}

struct KeyboardPresetChoiceTests {
    private static let sample = """
    { "schemaVersion": 1, "presets": [
      { "id": "third", "name": "Third", "platforms": ["macos"], "bindings": [ { "action": "newTab", "mac": "cmd+y" } ] }
    ] }
    """

    private func third() throws -> KeyboardPreset {
        try #require(try KeymapFixtures.catalog(Self.sample).presets.first)
    }

    @Test("Keep Current writes nothing")
    func keepCurrentWritesNothing() {
        #expect(KeyboardPresetChoice.keepCurrent.settings(isSystemHotkey: KeymapFixtures.noHotkeys) == nil)
    }

    @Test("TablePro writes the defaults")
    func tableProWritesDefaults() {
        #expect(KeyboardPresetChoice.tablePro.settings(isSystemHotkey: KeymapFixtures.noHotkeys) == KeyboardSettings.default)
    }

    @Test("A preset is applied over the defaults, never over the current shortcuts")
    func presetStartsFromDefaults() throws {
        let preset = try third()
        #expect(
            KeyboardPresetChoice.preset(preset).settings(isSystemHotkey: KeymapFixtures.noHotkeys)
                == KeyboardSettings.default.applying(preset, isSystemHotkey: KeymapFixtures.noHotkeys)
        )
    }

    @Test("Replacing asks first only over customized shortcuts that would change")
    func asksOnlyOverCustomized() throws {
        let preset = try third()
        let applied = KeyboardSettings.default.applying(preset, isSystemHotkey: KeymapFixtures.noHotkeys)
        let custom = KeyboardSettings(shortcuts: [ShortcutAction.refresh.rawValue: .special(.f5)])

        #expect(!KeyboardPresetChoice.asksBeforeReplacing(.default, with: applied))
        #expect(KeyboardPresetChoice.asksBeforeReplacing(custom, with: applied))
        #expect(KeyboardPresetChoice.asksBeforeReplacing(custom, with: .default))
        #expect(!KeyboardPresetChoice.asksBeforeReplacing(applied, with: applied))
    }
}

@MainActor
struct KeyboardPresetSummaryTests {
    @Test("The list bar names the preset the shortcuts match, else counts the changes")
    func summaryNamesThePreset() {
        #expect(KeyboardSettingsView.summary(customized: 4, preset: "Third") == String(format: String(localized: "%@ shortcuts"), "Third"))
        #expect(KeyboardSettingsView.summary(customized: 4, preset: nil) == KeyboardSettingsView.summary(customized: 4))
    }
}

struct KeyboardPresetGoldenTests {
    // Displaced default -> the preset command that takes its key, on a US layout with no system hotkeys.
    // A change here is a reviewed change to what a preset takes from TablePro's own commands.
    private static let displaced: [String: [String: String]] = [
        "tableplus": [
            "useSelectionForFind": "newTab",
            "saveAsFavorite": "duplicateRow",
        ],
        "sequelace": [
            "toggleResults": "executeAllStatements",
            "switchToRecentTab": "showNextTab",
            "switchToLeastRecentTab": "showPreviousTab",
            "toggleAssistant": "addRow",
            "saveAsFavorite": "duplicateRow",
            "findAndReplace": "toggleFilters",
            "refresh": "executeQuery",
        ],
        "dbeaver": [:],
        "datagrip": [
            "aiOptimizeQuery": "formatQuery",
            "openFile": "quickSwitcher",
            "saveAsFavorite": "duplicateRow",
            "explainQuery": "toggleHistory",
        ],
        "beekeeperstudio": [
            "switchToRecentTab": "showNextTab",
            "switchToLeastRecentTab": "showPreviousTab",
            "newConnection": "addRow",
            "saveAsFavorite": "duplicateRow",
            "copyRowsExplicit": "commitTransaction",
        ],
        "navicat": [
            "focusSidebarSearch": "toggleFilters",
            "toggleHeaderRow": "toggleHistory",
            "refresh": "executeAllStatements",
        ],
        "dbx": [
            "useSelectionForFind": "explainQuery",
            "copyWithHeaders": "newConnection",
            "saveAsFavorite": "duplicateRow",
        ],
    ]

    @Test("Every preset offered on the Mac has a golden")
    func everyPresetHasAGolden() throws {
        let ids = try KeymapFixtures.repoCatalog().listing(first: nil).map(\.id)
        #expect(Set(ids) == Set(Self.displaced.keys))
    }

    @Test("Each preset displaces exactly its pinned commands")
    func displacedSetPerPreset() throws {
        for preset in try KeymapFixtures.repoCatalog().listing(first: nil) {
            let settings = KeyboardSettings.default.applying(preset, isSystemHotkey: KeymapFixtures.noHotkeys)
            #expect(KeymapFixtures.displaced(in: settings) == Self.displaced[preset.id], "\(preset.id)")
        }
    }

    @Test("Every override a preset writes passes the recorder and avoids reserved keys")
    func writtenOverridesAreBindable() throws {
        for preset in try KeymapFixtures.repoCatalog().listing(first: nil) {
            let settings = KeyboardSettings.default.applying(preset, isSystemHotkey: KeymapFixtures.noHotkeys)
            for (rawValue, key) in settings.shortcuts {
                let action = try #require(ShortcutAction(rawValue: rawValue))
                #expect(action.accepts(key), "\(preset.id) \(rawValue) \(key.displayString)")
                #expect(
                    ShortcutAction.reservedConflict(for: key, context: action.context) == nil,
                    "\(preset.id) \(rawValue) \(key.displayString)"
                )
            }
            #expect(settings.sanitized() == settings, "\(preset.id)")
        }
    }

    @Test("No two commands a preset binds share a key where both can fire")
    func noCollisionAfterApplying() throws {
        let enabled = Set(AppModule.allCases)
        for preset in try KeymapFixtures.repoCatalog().listing(first: nil) {
            let settings = KeyboardSettings.default.applying(preset, isSystemHotkey: KeymapFixtures.noHotkeys)
            for action in ShortcutAction.allCases {
                guard let key = settings.boundKey(for: action) else { continue }
                let others = settings.conflicts(for: key, excluding: action, enabledModules: enabled)
                #expect(others.isEmpty, "\(preset.id): \(action.rawValue) shares \(key.displayString) with \(others.map { $0.rawValue })")
            }
        }
    }

    @Test("Each preset reads back as itself once applied")
    func appliedPresetRoundTrip() throws {
        let catalog = try KeymapFixtures.repoCatalog()
        for preset in catalog.listing(first: nil) {
            let settings = KeyboardSettings.default.applying(preset, isSystemHotkey: KeymapFixtures.noHotkeys)
            guard settings.isCustomized else { continue }
            #expect(settings.appliedPreset(in: catalog) == preset.id, "\(preset.id)")
        }
    }
}
