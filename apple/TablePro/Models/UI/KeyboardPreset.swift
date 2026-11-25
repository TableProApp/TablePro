import Foundation
import os

// core/crates/core/keymaps.json, the one preset file the Linux and Windows apps read too.
struct KeyboardPresetCatalog: Decodable, Equatable, Sendable {
    static let schemaVersion = 1

    private static let logger = Logger(subsystem: "com.TablePro", category: "KeyboardPreset")

    let presets: [KeyboardPreset]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case presets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported keymap schema \(version)"
            )
        }
        presets = try container.decode([KeyboardPreset].self, forKey: .presets)
    }

    static func decode(_ data: Data) throws -> KeyboardPresetCatalog {
        try JSONDecoder().decode(KeyboardPresetCatalog.self, from: data)
    }

    static func load(from url: URL) throws -> KeyboardPresetCatalog {
        try decode(Data(contentsOf: url))
    }

    static func bundled(_ bundle: Bundle = .main) -> KeyboardPresetCatalog? {
        guard let url = bundle.url(forResource: "keymaps", withExtension: "json") else {
            logger.error("The app bundle has no keymaps.json")
            return nil
        }
        do {
            return try load(from: url)
        } catch {
            logger.error("keymaps.json could not be read: \(error.publicLogShape, privacy: .public)")
            return nil
        }
    }

    func listing(first id: String?) -> [KeyboardPreset] {
        var listed = presets.filter(\.runsOnMac)
        if let id, let index = listed.firstIndex(where: { $0.id == id }) {
            listed.insert(listed.remove(at: index), at: 0)
        }
        return listed
    }
}

struct KeyboardPreset: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let platforms: [String]
    let bindings: [Binding]

    struct Binding: Decodable, Equatable, Sendable {
        let action: String
        let key: String?
        let mac: String?
        let linux: String?
        let windows: String?
        let derived: Bool

        private enum CodingKeys: String, CodingKey {
            case action, key, mac, linux, windows, derived
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            action = try container.decode(String.self, forKey: .action)
            key = try container.decodeIfPresent(String.self, forKey: .key)
            mac = try container.decodeIfPresent(String.self, forKey: .mac)
            linux = try container.decodeIfPresent(String.self, forKey: .linux)
            windows = try container.decodeIfPresent(String.self, forKey: .windows)
            derived = try container.decodeIfPresent(Bool.self, forKey: .derived) ?? false
        }
    }

    // Linux and Windows commands with no ShortcutAction; the Mac skips their rows.
    static let actionsWithoutMacCase: Set<String> = ["discardChanges", "showSettings"]

    var runsOnMac: Bool {
        platforms.contains("macos")
    }

    var macRows: [(action: ShortcutAction, chord: PresetChord)] {
        bindings.compactMap { binding in
            guard let text = binding.mac ?? binding.key,
                  let action = ShortcutAction(rawValue: binding.action),
                  let chord = PresetChord(text) else { return nil }
            return (action, chord)
        }
    }

    // Static filters only: the recorder's gate and the reserved keys. System hotkeys are the user's, so applying checks them.
    func macBindings(keyCode lookup: (Character) -> UInt16?) -> [(action: ShortcutAction, key: BoundKey)] {
        macRows.compactMap { row in
            guard let key = row.chord.boundKey(keyCode: lookup),
                  row.action.accepts(key),
                  ShortcutAction.reservedConflict(for: key, context: row.action.context) == nil else { return nil }
            return (row.action, key)
        }
    }
}

// VS Code chord grammar: modifiers in any order, then one key; `delete` is Forward Delete and `enter` is Return.
struct PresetChord: Hashable, Sendable {
    let key: String
    let control: Bool
    let shift: Bool
    let option: Bool
    let command: Bool

    init?(_ text: String) {
        let tokens = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let key = tokens.last, Self.isKnownKey(key) else { return nil }
        var control = false
        var shift = false
        var option = false
        var command = false
        for token in tokens.dropLast() {
            switch token {
            case "ctrl" where !control: control = true
            case "shift" where !shift: shift = true
            case "alt" where !option: option = true
            case "cmd" where !command: command = true
            default: return nil
            }
        }
        self.key = key
        self.control = control
        self.shift = shift
        self.option = option
        self.command = command
    }

    var boundKey: BoundKey? {
        boundKey(keyCode: KeyboardLayout.keyCode(for:))
    }

    // nil for a key a Mac keyboard lacks (Insert, F13 and up) or a character the layout cannot type.
    func boundKey(keyCode lookup: (Character) -> UInt16?) -> BoundKey? {
        let code: UInt16?
        if let named = Self.namedKeys[key] {
            code = named.rawValue
        } else if Self.characterKeys.contains(key), let character = key.first {
            code = lookup(character)
        } else {
            code = nil
        }
        guard let code else { return nil }
        return BoundKey(keyCode: code, command: command, shift: shift, option: option, control: control)
    }

    private static let characterKeys: Set<String> = {
        var keys = Set("abcdefghijklmnopqrstuvwxyz0123456789".map(String.init))
        keys.formUnion(["`", "-", "=", "[", "]", "\\", ";", "'", ",", ".", "/"])
        return keys
    }()

    private static let namedKeys: [String: KeyCode] = [
        "left": .leftArrow, "up": .upArrow, "right": .rightArrow, "down": .downArrow,
        "pageup": .pageUp, "pagedown": .pageDown, "home": .home, "end": .end,
        "tab": .tab, "enter": .return, "escape": .escape, "space": .space,
        "backspace": .delete, "delete": .forwardDelete,
        "f1": .f1, "f2": .f2, "f3": .f3, "f4": .f4, "f5": .f5, "f6": .f6,
        "f7": .f7, "f8": .f8, "f9": .f9, "f10": .f10, "f11": .f11, "f12": .f12,
    ]

    private static let keysWithoutMacKey: Set<String> = ["insert", "f13", "f14", "f15", "f16", "f17", "f18", "f19"]

    private static func isKnownKey(_ key: String) -> Bool {
        characterKeys.contains(key) || namedKeys[key] != nil || keysWithoutMacKey.contains(key)
    }
}

extension KeyboardSettings {
    var isCustomized: Bool {
        customizedCount > 0
    }

    // Writes no clears: a default a row takes yields through the claimant rule, and resetting that row re-arms it.
    func applying(
        _ preset: KeyboardPreset,
        isSystemHotkey: (BoundKey) -> Bool,
        keyCode lookup: (Character) -> UInt16? = KeyboardLayout.keyCode(for:)
    ) -> KeyboardSettings {
        var next = self
        for (action, key) in preset.macBindings(keyCode: lookup) where !isSystemHotkey(key) {
            if key == Self.defaultShortcuts[action] {
                next.resetToDefault(for: action)
            } else {
                next.setShortcut(key, for: action)
            }
        }
        return next
    }

    @MainActor
    func applying(_ preset: KeyboardPreset) -> KeyboardSettings {
        applying(preset, isSystemHotkey: { SystemHotkeyChecker.shared.isReserved($0) })
    }

    // A row a system hotkey kept out may be missing, so the closest preset holding every override wins; nil reads as Custom.
    func appliedPreset(
        in catalog: KeyboardPresetCatalog,
        keyCode lookup: (Character) -> UInt16? = KeyboardLayout.keyCode(for:)
    ) -> KeyboardPreset.ID? {
        let overrides = shortcuts.filter { ShortcutAction(rawValue: $0.key) != nil }
        guard !overrides.isEmpty else { return nil }
        var best: (id: KeyboardPreset.ID, missing: Int)?
        for preset in catalog.listing(first: nil) {
            var rows: [String: BoundKey] = [:]
            for (action, key) in preset.macBindings(keyCode: lookup) where key != Self.defaultShortcuts[action] {
                rows[action.rawValue] = key
            }
            guard overrides.allSatisfy({ rows[$0.key] == $0.value }) else { continue }
            let missing = rows.count - overrides.count
            if best.map({ missing < $0.missing }) ?? true {
                best = (preset.id, missing)
            }
        }
        return best?.id
    }
}

enum KeyboardPresetChoice: Equatable, Sendable {
    case keepCurrent
    case tablePro
    case preset(KeyboardPreset)

    // nil writes nothing. A preset starts from the defaults, so two presets never stack.
    func settings(isSystemHotkey: (BoundKey) -> Bool) -> KeyboardSettings? {
        switch self {
        case .keepCurrent: nil
        case .tablePro: .default
        case .preset(let preset): KeyboardSettings.default.applying(preset, isSystemHotkey: isSystemHotkey)
        }
    }

    static func asksBeforeReplacing(_ current: KeyboardSettings, with next: KeyboardSettings) -> Bool {
        current.isCustomized && current != next
    }
}
