//
//  BoundKey.swift
//  TablePro
//
//  A keyboard shortcut stored as a hardware key code plus modifiers. Storing the
//  physical key code (rather than the produced character) makes matching
//  layout-independent and avoids the shifted-symbol ambiguity where "[" and "{"
//  describe the same physical key.
//

import AppKit
import SwiftUI

struct BoundKey: Codable, Equatable, Hashable {
    let keyCode: UInt16
    let command: Bool
    let shift: Bool
    let option: Bool
    let control: Bool

    init(keyCode: UInt16, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.keyCode = keyCode
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    // MARK: - Recorder Capture

    /// Build from a recorded key event. Requires Command or Control, or one of the
    /// bare keys allowed for grid actions (Escape, Delete, Forward Delete, Space).
    init?(from event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommand = flags.contains(.command)
        let hasControl = flags.contains(.control)
        guard hasCommand || hasControl || Self.isBareRecordable(event.keyCode) else {
            return nil
        }
        self.keyCode = event.keyCode
        self.command = hasCommand
        self.shift = flags.contains(.shift)
        self.option = flags.contains(.option)
        self.control = hasControl
    }

    // MARK: - Default Construction

    /// Build a binding from a base character, resolving it to a key code on the
    /// active layout. Used to anchor default shortcuts to a semantic character.
    /// A character with no key code on the active layout yields the cleared
    /// sentinel, so the binding reads as unassigned rather than silently aliasing
    /// some other physical key. Every default and reserved character is ASCII and
    /// resolves through the US fallback, so the failure path is a programmer error
    /// and trips an assertion in debug.
    static func character(
        _ character: Character,
        command: Bool = false,
        shift: Bool = false,
        option: Bool = false,
        control: Bool = false
    ) -> BoundKey {
        guard let keyCode = KeyboardLayout.keyCode(for: character) else {
            assertionFailure("No key code for '\(character)' on the active keyboard layout")
            return .cleared
        }
        return BoundKey(keyCode: keyCode, command: command, shift: shift, option: option, control: control)
    }

    /// Build a binding from a named special key (layout-independent).
    static func special(
        _ key: KeyCode,
        command: Bool = false,
        shift: Bool = false,
        option: Bool = false,
        control: Bool = false
    ) -> BoundKey {
        BoundKey(keyCode: key.rawValue, command: command, shift: shift, option: option, control: control)
    }

    // MARK: - Migration

    /// Convert a legacy character-string shortcut (pre-keyCode storage) to a BoundKey.
    init?(legacyKey: String, isSpecialKey: Bool, command: Bool, shift: Bool, option: Bool, control: Bool) {
        if legacyKey.isEmpty, !command, !shift, !option, !control {
            self = .cleared
            return
        }
        let resolvedKeyCode: UInt16?
        if isSpecialKey {
            resolvedKeyCode = Self.specialKeyByLegacyName[legacyKey]?.rawValue
        } else if legacyKey.count == 1, let character = legacyKey.first {
            resolvedKeyCode = KeyboardLayout.keyCode(for: character)
        } else {
            resolvedKeyCode = nil
        }
        guard let keyCode = resolvedKeyCode else { return nil }
        self.init(keyCode: keyCode, command: command, shift: shift, option: option, control: control)
    }

    // MARK: - Matching

    func matches(_ event: NSEvent) -> Bool {
        guard !isCleared else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return event.keyCode == keyCode
            && flags.contains(.command) == command
            && flags.contains(.shift) == shift
            && flags.contains(.option) == option
            && flags.contains(.control) == control
    }

    var hasModifier: Bool {
        command || shift || option || control
    }

    /// Function keys (F1-F12) are valid as bare shortcuts: they reach the menu as
    /// key-equivalents without a modifier and never collide with typing.
    var isFunctionKey: Bool {
        KeyCode(rawValue: keyCode)?.functionKeyIndex != nil
    }

    // MARK: - SwiftUI Integration

    /// The SwiftUI key equivalent, or nil when the key code has no representable key.
    var swiftUIKeyEquivalent: KeyEquivalent? {
        if let special = Self.specialKeyEquivalent(for: keyCode) {
            return special
        }
        if let scalar = Self.functionKeyScalar(for: keyCode) {
            return KeyEquivalent(Character(scalar))
        }
        guard let character = KeyboardLayout.baseCharacter(for: keyCode) else { return nil }
        return KeyEquivalent(character)
    }

    var eventModifiers: EventModifiers {
        var modifiers: EventModifiers = []
        if command { modifiers.insert(.command) }
        if shift { modifiers.insert(.shift) }
        if option { modifiers.insert(.option) }
        if control { modifiers.insert(.control) }
        return modifiers
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }
        if shift { flags.insert(.shift) }
        if option { flags.insert(.option) }
        if control { flags.insert(.control) }
        return flags
    }

    // MARK: - Display

    /// Human-readable representation (e.g. "⌘S", "⇧⌘P", "⌥⌫").
    var displayString: String {
        guard !isCleared else { return "" }
        var parts: [String] = []
        if control { parts.append("⌃") }
        if option { parts.append("⌥") }
        if shift { parts.append("⇧") }
        if command { parts.append("⌘") }
        parts.append(displayKey)
        return parts.joined()
    }

    private var displayKey: String {
        if let glyph = Self.specialKeyGlyph(for: keyCode) {
            return glyph
        }
        if let index = KeyCode(rawValue: keyCode)?.functionKeyIndex {
            return "F\(index)"
        }
        if let character = KeyboardLayout.baseCharacter(for: keyCode) {
            return String(character).uppercased()
        }
        return "?"
    }

    // MARK: - Cleared Sentinel

    static let cleared = BoundKey(keyCode: 0xFFFF)

    var isCleared: Bool {
        keyCode == 0xFFFF
    }

    // MARK: - Special Key Tables

    private static let bareRecordableKeyCodes: Set<UInt16> = [
        KeyCode.escape.rawValue,
        KeyCode.delete.rawValue,
        KeyCode.forwardDelete.rawValue,
        KeyCode.space.rawValue
    ]

    private static func isBareRecordable(_ keyCode: UInt16) -> Bool {
        bareRecordableKeyCodes.contains(keyCode) || KeyCode(rawValue: keyCode)?.functionKeyIndex != nil
    }

    private static func functionKeyScalar(for keyCode: UInt16) -> Unicode.Scalar? {
        guard let index = KeyCode(rawValue: keyCode)?.functionKeyIndex else { return nil }
        return Unicode.Scalar(0xF704 + index - 1)
    }

    private static let specialKeyByLegacyName: [String: KeyCode] = [
        "delete": .delete,
        "forwardDelete": .forwardDelete,
        "escape": .escape,
        "return": .return,
        "tab": .tab,
        "space": .space,
        "upArrow": .upArrow,
        "downArrow": .downArrow,
        "leftArrow": .leftArrow,
        "rightArrow": .rightArrow,
        "home": .home,
        "end": .end,
        "pageUp": .pageUp,
        "pageDown": .pageDown
    ]

    private static func specialKeyEquivalent(for keyCode: UInt16) -> KeyEquivalent? {
        switch KeyCode(rawValue: keyCode) {
        case .delete: return .delete
        case .forwardDelete: return .deleteForward
        case .escape: return .escape
        case .return, .enter: return .return
        case .tab: return .tab
        case .space: return .space
        case .upArrow: return .upArrow
        case .downArrow: return .downArrow
        case .leftArrow: return .leftArrow
        case .rightArrow: return .rightArrow
        case .home: return .home
        case .end: return .end
        case .pageUp: return .pageUp
        case .pageDown: return .pageDown
        default: return nil
        }
    }

    private static func specialKeyGlyph(for keyCode: UInt16) -> String? {
        switch KeyCode(rawValue: keyCode) {
        case .delete: return "⌫"
        case .forwardDelete: return "⌦"
        case .escape: return "⎋"
        case .return: return "↩"
        case .enter: return "⌅"
        case .tab: return "⇥"
        case .space: return "␣"
        case .upArrow: return "↑"
        case .downArrow: return "↓"
        case .leftArrow: return "←"
        case .rightArrow: return "→"
        case .home: return "↖"
        case .end: return "↘"
        case .pageUp: return "⇞"
        case .pageDown: return "⇟"
        default: return nil
        }
    }
}
