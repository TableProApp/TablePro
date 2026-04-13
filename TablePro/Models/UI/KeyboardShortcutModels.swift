//
//  KeyboardShortcutModels.swift
//  TablePro
//
//  Data models for keyboard shortcut customization.
//

import AppKit
import SwiftUI

// MARK: - Shortcut Category

/// Categories for organizing keyboard shortcuts in settings
enum ShortcutCategory: String, Codable, CaseIterable, Identifiable {
    case file
    case edit
    case view
    case tabs
    case ai

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .file: return String(localized: "File")
        case .edit: return String(localized: "Edit")
        case .view: return String(localized: "View")
        case .tabs: return String(localized: "Tabs")
        case .ai: return String(localized: "AI")
        }
    }
}

// MARK: - Shortcut Action

/// All customizable keyboard shortcut actions
enum ShortcutAction: String, Codable, CaseIterable, Identifiable {
    // File
    case manageConnections
    case newTab
    case openDatabase
    case openFile
    case switchConnection
    case saveChanges
    case saveAs
    case previewSQL
    case closeTab
    case refresh
    case executeQuery
    case explainQuery
    case formatQuery
    case export
    case importData
    case quickSwitcher

    // Navigation
    case previousPage
    case nextPage

    // Edit
    case undo
    case redo
    case cut
    case copy
    case copyWithHeaders
    case copyAsJson
    case paste
    case delete
    case selectAll
    case clearSelection
    case addRow
    case duplicateRow
    case truncateTable
    case previewFKReference

    // View
    case toggleTableBrowser
    case toggleInspector
    case toggleFilters
    case toggleHistory
    case toggleResults
    case previousResultTab
    case nextResultTab
    case closeResultTab

    // Tabs
    case showPreviousTab
    case showNextTab

    // AI
    case aiExplainQuery
    case aiOptimizeQuery

    var id: String { rawValue }

    var category: ShortcutCategory {
        switch self {
        case .manageConnections, .newTab, .openDatabase, .openFile, .switchConnection,
             .saveChanges, .saveAs, .previewSQL, .closeTab, .refresh,
             .executeQuery, .explainQuery, .formatQuery, .export, .importData, .quickSwitcher,
             .previousPage, .nextPage:
            return .file
        case .undo, .redo, .cut, .copy, .copyWithHeaders, .copyAsJson, .paste,
             .delete, .selectAll, .clearSelection, .addRow,
             .duplicateRow, .truncateTable, .previewFKReference:
            return .edit
        case .toggleTableBrowser, .toggleInspector, .toggleFilters, .toggleHistory,
             .toggleResults, .previousResultTab, .nextResultTab, .closeResultTab:
            return .view
        case .showPreviousTab, .showNextTab:
            return .tabs
        case .aiExplainQuery, .aiOptimizeQuery:
            return .ai
        }
    }

    var displayName: String {
        switch self {
        case .manageConnections: return String(localized: "Manage Connections")
        case .executeQuery: return String(localized: "Execute Query")
        case .newTab: return String(localized: "New Tab")
        case .openDatabase: return String(localized: "Open Database")
        case .openFile: return String(localized: "Open File")
        case .switchConnection: return String(localized: "Switch Connection")
        case .saveChanges: return String(localized: "Save Changes")
        case .saveAs: return String(localized: "Save As")
        case .previewSQL: return String(localized: "Preview SQL")
        case .closeTab: return String(localized: "Close Tab")
        case .refresh: return String(localized: "Refresh")
        case .explainQuery: return String(localized: "Explain Query")
        case .formatQuery: return String(localized: "Format Query")
        case .export: return String(localized: "Export")
        case .importData: return String(localized: "Import")
        case .quickSwitcher: return String(localized: "Quick Switcher")
        case .previousPage: return String(localized: "Previous Page")
        case .nextPage: return String(localized: "Next Page")
        case .undo: return String(localized: "Undo")
        case .redo: return String(localized: "Redo")
        case .cut: return String(localized: "Cut")
        case .copy: return String(localized: "Copy")
        case .copyWithHeaders: return String(localized: "Copy with Headers")
        case .copyAsJson: return String(localized: "Copy as JSON")
        case .paste: return String(localized: "Paste")
        case .delete: return String(localized: "Delete")
        case .selectAll: return String(localized: "Select All")
        case .clearSelection: return String(localized: "Clear Selection")
        case .addRow: return String(localized: "Add Row")
        case .duplicateRow: return String(localized: "Duplicate Row")
        case .truncateTable: return String(localized: "Truncate Table")
        case .previewFKReference: return String(localized: "Preview FK Reference")
        case .toggleTableBrowser: return String(localized: "Toggle Table Browser")
        case .toggleInspector: return String(localized: "Toggle Inspector")
        case .toggleFilters: return String(localized: "Toggle Filters")
        case .toggleHistory: return String(localized: "Toggle History")
        case .toggleResults: return String(localized: "Toggle Results")
        case .previousResultTab: return String(localized: "Previous Result")
        case .nextResultTab: return String(localized: "Next Result")
        case .closeResultTab: return String(localized: "Close Result Tab")
        case .showPreviousTab: return String(localized: "Show Previous Tab")
        case .showNextTab: return String(localized: "Show Next Tab")
        case .aiExplainQuery: return String(localized: "Explain with AI")
        case .aiOptimizeQuery: return String(localized: "Optimize with AI")
        }
    }
}

// MARK: - Key Combo

/// A recorded keyboard shortcut combination
struct KeyCombo: Codable, Equatable, Hashable {
    /// The key character (lowercase letter, or special key name like "delete", "escape", "leftArrow", etc.)
    let key: String

    /// Whether Command modifier is held
    let command: Bool

    /// Whether Shift modifier is held
    let shift: Bool

    /// Whether Option modifier is held
    let option: Bool

    /// Whether Control modifier is held
    let control: Bool

    /// Whether this is a special key (arrow, delete, escape, etc.) rather than a character key
    let isSpecialKey: Bool

    init(
        key: String,
        command: Bool = false,
        shift: Bool = false,
        option: Bool = false,
        control: Bool = false,
        isSpecialKey: Bool = false
    ) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
        self.isSpecialKey = isSpecialKey
    }

    /// Create a KeyCombo from an NSEvent
    init?(from event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommand = flags.contains(.command)
        let hasShift = flags.contains(.shift)
        let hasOption = flags.contains(.option)
        let hasControl = flags.contains(.control)

        // Require at least Cmd or Control (or special bare keys: escape, delete, space)
        let specialKeyCode = Self.specialKeyName(for: event.keyCode)
        let isAllowedBareKey = event.keyCode == 53 || event.keyCode == 51
            || event.keyCode == 117 || event.keyCode == 49

        if !hasCommand && !hasControl && !isAllowedBareKey {
            return nil
        }

        if let specialName = specialKeyCode {
            self.key = specialName
            self.isSpecialKey = true
        } else if let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty {
            self.key = chars
            self.isSpecialKey = false
        } else {
            return nil
        }

        self.command = hasCommand
        self.shift = hasShift
        self.option = hasOption
        self.control = hasControl
    }

    // MARK: - SwiftUI Integration

    /// Convert to SwiftUI KeyEquivalent
    var keyEquivalent: KeyEquivalent {
        if isSpecialKey {
            switch key {
            case "delete": return .delete
            case "escape": return .escape
            case "return": return .return
            case "tab": return .tab
            case "space": return .space
            case "upArrow": return .upArrow
            case "downArrow": return .downArrow
            case "leftArrow": return .leftArrow
            case "rightArrow": return .rightArrow
            case "home": return .home
            case "end": return .end
            case "pageUp": return .pageUp
            case "pageDown": return .pageDown
            // NSDeleteFunctionKey (0xF728) is always a valid Unicode scalar
            // swiftlint:disable:next force_unwrapping
            case "forwardDelete": return KeyEquivalent(Character(UnicodeScalar(NSDeleteFunctionKey)!))
            default:
                guard key.count == 1 else { return .escape }
                return KeyEquivalent(Character(key))
            }
        }
        return KeyEquivalent(Character(key))
    }

    /// Convert to SwiftUI EventModifiers
    var eventModifiers: EventModifiers {
        var modifiers: EventModifiers = []
        if command { modifiers.insert(.command) }
        if shift { modifiers.insert(.shift) }
        if option { modifiers.insert(.option) }
        if control { modifiers.insert(.control) }
        return modifiers
    }

    /// Human-readable display string (e.g. "⌘S", "⇧⌘P")
    var displayString: String {
        var parts: [String] = []
        if control { parts.append("⌃") }
        if option { parts.append("⌥") }
        if shift { parts.append("⇧") }
        if command { parts.append("⌘") }
        parts.append(displayKey)
        return parts.joined()
    }

    /// The display representation of the key
    private var displayKey: String {
        if isSpecialKey {
            switch key {
            case "delete": return "⌫"
            case "forwardDelete": return "⌦"
            case "escape": return "⎋"
            case "return": return "↩"
            case "tab": return "⇥"
            case "space": return "␣"
            case "upArrow": return "↑"
            case "downArrow": return "↓"
            case "leftArrow": return "←"
            case "rightArrow": return "→"
            case "home": return "↖"
            case "end": return "↘"
            case "pageUp": return "⇞"
            case "pageDown": return "⇟"
            default: return key.count == 1 ? key.uppercased() : "?"
            }
        }
        return key.uppercased()
    }

    // MARK: - Special Key Mapping

    /// Map macOS key codes to special key names
    private static func specialKeyName(for keyCode: UInt16) -> String? {
        switch keyCode {
        case 51: return "delete"
        case 117: return "forwardDelete"
        case 53: return "escape"
        case 36: return "return"
        case 48: return "tab"
        case 49: return "space"
        case 126: return "upArrow"
        case 125: return "downArrow"
        case 123: return "leftArrow"
        case 124: return "rightArrow"
        case 115: return "home"
        case 119: return "end"
        case 116: return "pageUp"
        case 121: return "pageDown"
        default: return nil
        }
    }

    // MARK: - Event Matching

    /// Check if this combo matches a given NSEvent (for runtime key dispatch)
    func matches(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard command == flags.contains(.command),
              shift == flags.contains(.shift),
              option == flags.contains(.option),
              control == flags.contains(.control)
        else { return false }
        if isSpecialKey {
            return Self.specialKeyName(for: event.keyCode) == key
        }
        return event.charactersIgnoringModifiers?.lowercased() == key
    }

    // MARK: - System Reserved Check

    /// Shortcuts that are reserved by macOS and should not be overridden
    static let systemReserved: [KeyCombo] = [
        KeyCombo(key: "q", command: true),           // Quit
        KeyCombo(key: "h", command: true),            // Hide
        KeyCombo(key: "m", command: true),            // Minimize
        KeyCombo(key: ",", command: true),             // Settings
        KeyCombo(key: "tab", command: true, isSpecialKey: true),  // App switcher
        KeyCombo(key: "space", command: true, isSpecialKey: true), // Spotlight
        KeyCombo(key: "`", command: true),             // Window cycling
        KeyCombo(key: "escape", command: true, option: true, isSpecialKey: true), // Force Quit
        KeyCombo(key: "q", command: true, shift: true), // Logout
        KeyCombo(key: "3", command: true, shift: true), // Screenshot full
        KeyCombo(key: "4", command: true, shift: true), // Screenshot area
        KeyCombo(key: "5", command: true, shift: true), // Screenshot options
    ]

    /// Check if this combo is reserved by the system
    var isSystemReserved: Bool {
        Self.systemReserved.contains(self)
    }
}

// MARK: - Keyboard Settings

/// User's keyboard shortcut customization settings
/// Only stores overrides — empty dictionary means all defaults
struct KeyboardSettings: Codable, Equatable {
    /// User-customized shortcuts (action rawValue → KeyCombo)
    /// Only contains overrides; missing entries use defaults.
    /// Keys are ShortcutAction raw values — if a raw value is renamed in a future version,
    /// the old stored key becomes a harmless no-op (never matched by any action).
    var shortcuts: [String: KeyCombo]

    static let `default` = KeyboardSettings(shortcuts: [:])

    init(shortcuts: [String: KeyCombo] = [:]) {
        self.shortcuts = shortcuts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shortcuts = try container.decodeIfPresent([String: KeyCombo].self, forKey: .shortcuts) ?? [:]
    }

    /// Get the effective shortcut for an action (user override or default)
    /// Returns nil if user explicitly cleared the shortcut
    func shortcut(for action: ShortcutAction) -> KeyCombo? {
        if let override = shortcuts[action.rawValue] {
            return override
        }
        return Self.defaultShortcuts[action]
    }

    /// Check if user has customized the shortcut for an action
    func isCustomized(_ action: ShortcutAction) -> Bool {
        shortcuts[action.rawValue] != nil
    }

    /// Find a conflicting action for the given combo, excluding the specified action
    func findConflict(for combo: KeyCombo, excluding action: ShortcutAction) -> ShortcutAction? {
        for otherAction in ShortcutAction.allCases where otherAction != action {
            if shortcut(for: otherAction) == combo {
                return otherAction
            }
        }
        return nil
    }

    /// Set a shortcut override for an action
    mutating func setShortcut(_ combo: KeyCombo, for action: ShortcutAction) {
        shortcuts[action.rawValue] = combo
    }

    /// Clear a shortcut (remove it, action will have no shortcut)
    mutating func clearShortcut(for action: ShortcutAction) {
        // Store a special "empty" combo to indicate explicitly unassigned
        shortcuts[action.rawValue] = KeyCombo.cleared
    }

    /// Reset a specific action to its default shortcut
    mutating func resetToDefault(for action: ShortcutAction) {
        shortcuts.removeValue(forKey: action.rawValue)
    }

    /// Build a SwiftUI KeyboardShortcut for the given action.
    /// Returns nil if the user has cleared (unassigned) the shortcut.
    func keyboardShortcut(for action: ShortcutAction) -> KeyboardShortcut? {
        guard let combo = shortcut(for: action), !combo.isCleared else {
            return nil
        }
        return KeyboardShortcut(combo.keyEquivalent, modifiers: combo.eventModifiers)
    }

    // MARK: - Default Shortcuts

    /// Default shortcuts — applied when user has no overrides
    static let defaultShortcuts: [ShortcutAction: KeyCombo] = [
        // File
        .manageConnections: KeyCombo(key: "n", command: true),
        .executeQuery: KeyCombo(key: "return", command: true, isSpecialKey: true),
        .newTab: KeyCombo(key: "t", command: true),
        .openDatabase: KeyCombo(key: "k", command: true),
        .openFile: KeyCombo(key: "o", command: true),
        .switchConnection: KeyCombo(key: "c", command: true, control: true),
        .saveChanges: KeyCombo(key: "s", command: true),
        .saveAs: KeyCombo(key: "s", command: true, shift: true),
        .previewSQL: KeyCombo(key: "p", command: true, shift: true),
        .closeTab: KeyCombo(key: "w", command: true),
        .refresh: KeyCombo(key: "r", command: true),
        .explainQuery: KeyCombo(key: "e", command: true, option: true),
        .formatQuery: KeyCombo(key: "f", command: true, option: true),
        .export: KeyCombo(key: "e", command: true, shift: true),
        .importData: KeyCombo(key: "i", command: true, shift: true),
        .quickSwitcher: KeyCombo(key: "p", command: true),
        .previousPage: KeyCombo(key: "[", command: true),
        .nextPage: KeyCombo(key: "]", command: true),

        // Edit
        .undo: KeyCombo(key: "z", command: true),
        .redo: KeyCombo(key: "z", command: true, shift: true),
        .cut: KeyCombo(key: "x", command: true),
        .copy: KeyCombo(key: "c", command: true),
        .copyWithHeaders: KeyCombo(key: "c", command: true, shift: true),
        .copyAsJson: KeyCombo(key: "j", command: true, option: true),
        .paste: KeyCombo(key: "v", command: true),
        .delete: KeyCombo(key: "delete", command: true, isSpecialKey: true),
        .selectAll: KeyCombo(key: "a", command: true),
        .clearSelection: KeyCombo(key: "escape", isSpecialKey: true),
        .addRow: KeyCombo(key: "n", command: true, shift: true),
        .duplicateRow: KeyCombo(key: "d", command: true, shift: true),
        .truncateTable: KeyCombo(key: "delete", option: true, isSpecialKey: true),
        .previewFKReference: KeyCombo(key: "space", isSpecialKey: true),

        // View
        .toggleTableBrowser: KeyCombo(key: "0", command: true),
        .toggleInspector: KeyCombo(key: "i", command: true, option: true),
        .toggleFilters: KeyCombo(key: "f", command: true, shift: true),
        .toggleHistory: KeyCombo(key: "y", command: true),
        .toggleResults: KeyCombo(key: "r", command: true, option: true),
        .previousResultTab: KeyCombo(key: "[", command: true, option: true),
        .nextResultTab: KeyCombo(key: "]", command: true, option: true),
        .closeResultTab: KeyCombo(key: "w", command: true, shift: true),

        // Tabs
        .showPreviousTab: KeyCombo(key: "[", command: true, shift: true),
        .showNextTab: KeyCombo(key: "]", command: true, shift: true),

        // AI
        .aiExplainQuery: KeyCombo(key: "l", command: true),
        .aiOptimizeQuery: KeyCombo(key: "l", command: true, option: true),
    ]
}

// MARK: - KeyCombo Cleared Sentinel

extension KeyCombo {
    /// Sentinel value representing an explicitly cleared (unassigned) shortcut
    static let cleared = KeyCombo(key: "", command: false, shift: false, option: false, control: false, isSpecialKey: false)

    /// Whether this combo represents an explicitly cleared shortcut
    var isCleared: Bool {
        key.isEmpty && !command && !shift && !option && !control
    }
}
