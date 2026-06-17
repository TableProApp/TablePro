//
//  KeyboardShortcutModels.swift
//  TablePro
//
//  Data models for keyboard shortcut customization. The binding type itself
//  lives in BoundKey.swift.
//

import AppKit
import SwiftUI

// MARK: - Shortcut Context

/// Where an action can fire. The same physical combo can mean different things
/// in different contexts because the focused responder resolves it (e.g. Cmd+[
/// is pagination in the grid and indent in the editor). Two actions only
/// conflict when their contexts can be active at the same time.
enum ShortcutContext: String {
    case global
    case editor
    case dataGrid

    /// Two contexts overlap when they can be the active responder at the same
    /// time. Non-overlapping contexts (editor vs data grid) may share a combo:
    /// the editor's local key monitor consumes the keystroke while it is focused,
    /// so the grid's menu key-equivalent only fires when the grid has focus. The
    /// conflict resolver guards uniqueness within an overlapping context; it does
    /// not stop a user from binding a grid combo that also reaches a global menu
    /// item, which focus alone cannot disambiguate.
    func overlaps(_ other: ShortcutContext) -> Bool {
        self == .global || other == .global || self == other
    }
}

// MARK: - Shortcut Category

/// Groups shortcuts in the settings list by the surface they act on.
enum ShortcutCategory: String, Codable, CaseIterable, Identifiable {
    case editor
    case dataGrid
    case navigation
    case connections
    case app

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .editor: return String(localized: "Editor & Query")
        case .dataGrid: return String(localized: "Data Grid")
        case .navigation: return String(localized: "Navigation")
        case .connections: return String(localized: "Connections")
        case .app: return String(localized: "App")
        }
    }
}

// MARK: - Shortcut Action

/// All customizable keyboard shortcut actions
enum ShortcutAction: String, Codable, CaseIterable, Identifiable {
    // Connections
    case manageConnections
    case newConnection
    case openDatabase
    case switchConnection

    // Editor & Query
    case openFile
    case saveChanges
    case saveAs
    case executeQuery
    case executeAllStatements
    case cancelQuery
    case explainQuery
    case formatQuery
    case previewSQL
    case findNext
    case findPrevious
    case aiExplainQuery
    case aiOptimizeQuery

    // Data Grid
    case undo
    case redo
    case cut
    case copy
    case copyRowsExplicit
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
    case saveAsFavorite
    case previousPage
    case nextPage
    case firstPage
    case lastPage
    case refresh
    case export
    case importData

    // Navigation
    case newTab
    case closeTab
    case quickSwitcher
    case toggleTableBrowser
    case toggleInspector
    case toggleFilters
    case toggleHistory
    case toggleResults
    case previousResultTab
    case nextResultTab
    case closeResultTab
    case focusSidebarSearch
    case showSidebarTables
    case showSidebarFavorites
    case showPreviousTab
    case showNextTab

    var id: String { rawValue }

    var category: ShortcutCategory {
        switch self {
        case .manageConnections, .newConnection, .openDatabase, .switchConnection:
            return .connections
        case .openFile, .saveChanges, .saveAs, .executeQuery, .executeAllStatements,
             .cancelQuery, .explainQuery, .formatQuery, .previewSQL, .findNext,
             .findPrevious, .aiExplainQuery, .aiOptimizeQuery:
            return .editor
        case .undo, .redo, .cut, .copy, .copyRowsExplicit, .copyWithHeaders, .copyAsJson,
             .paste, .delete, .selectAll, .clearSelection, .addRow, .duplicateRow,
             .truncateTable, .previewFKReference, .saveAsFavorite, .previousPage,
             .nextPage, .firstPage, .lastPage, .refresh, .export, .importData:
            return .dataGrid
        case .newTab, .closeTab, .quickSwitcher, .toggleTableBrowser, .toggleInspector,
             .toggleFilters, .toggleHistory, .toggleResults, .previousResultTab,
             .nextResultTab, .closeResultTab, .focusSidebarSearch, .showSidebarTables,
             .showSidebarFavorites, .showPreviousTab, .showNextTab:
            return .navigation
        }
    }

    var context: ShortcutContext {
        switch self {
        case .executeQuery, .executeAllStatements, .cancelQuery, .explainQuery,
             .formatQuery, .previewSQL, .findNext, .findPrevious, .aiExplainQuery,
             .aiOptimizeQuery:
            return .editor
        case .previousPage, .nextPage, .firstPage, .lastPage, .addRow, .duplicateRow,
             .delete, .truncateTable, .previewFKReference, .saveAsFavorite,
             .copyRowsExplicit, .copyWithHeaders, .copyAsJson, .toggleFilters:
            return .dataGrid
        default:
            return .global
        }
    }

    var allowsBareKey: Bool {
        switch self {
        case .previewFKReference, .clearSelection, .delete:
            return true
        default:
            return false
        }
    }

    var displayName: String {
        switch self {
        case .manageConnections: return String(localized: "Manage Connections")
        case .newConnection: return String(localized: "New Connection")
        case .executeQuery: return String(localized: "Execute Query")
        case .executeAllStatements: return String(localized: "Execute All Statements")
        case .cancelQuery: return String(localized: "Cancel Query")
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
        case .findNext: return String(localized: "Find Next")
        case .findPrevious: return String(localized: "Find Previous")
        case .export: return String(localized: "Export")
        case .importData: return String(localized: "Import")
        case .quickSwitcher: return String(localized: "Quick Switcher")
        case .previousPage: return String(localized: "Previous Page")
        case .nextPage: return String(localized: "Next Page")
        case .firstPage: return String(localized: "First Page")
        case .lastPage: return String(localized: "Last Page")
        case .undo: return String(localized: "Undo")
        case .redo: return String(localized: "Redo")
        case .cut: return String(localized: "Cut")
        case .copy: return String(localized: "Copy")
        case .copyRowsExplicit: return String(localized: "Copy Rows")
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
        case .saveAsFavorite: return String(localized: "Save as Favorite")
        case .toggleTableBrowser: return String(localized: "Toggle Table Browser")
        case .toggleInspector: return String(localized: "Toggle Inspector")
        case .toggleFilters: return String(localized: "Toggle Filters")
        case .toggleHistory: return String(localized: "Toggle History")
        case .toggleResults: return String(localized: "Toggle Results")
        case .previousResultTab: return String(localized: "Previous Result")
        case .nextResultTab: return String(localized: "Next Result")
        case .closeResultTab: return String(localized: "Close Result Tab")
        case .focusSidebarSearch: return String(localized: "Focus Sidebar Filter")
        case .showSidebarTables: return String(localized: "Show Tables Sidebar")
        case .showSidebarFavorites: return String(localized: "Show Favorites Sidebar")
        case .showPreviousTab: return String(localized: "Show Previous Tab")
        case .showNextTab: return String(localized: "Show Next Tab")
        case .aiExplainQuery: return String(localized: "Explain with AI")
        case .aiOptimizeQuery: return String(localized: "Optimize with AI")
        }
    }
}

// MARK: - Built-in Editor Shortcuts

extension ShortcutAction {
    /// Shortcuts owned by the embedded SQL editor. They are not customizable, but
    /// the recorder surfaces them so a user does not silently shadow one with an
    /// editor-context binding.
    static let editorBuiltIns: [(key: BoundKey, name: String)] = [
        (.character("/", command: true), String(localized: "Toggle Comment")),
        (.character("[", command: true), String(localized: "Indent")),
        (.character("]", command: true), String(localized: "Outdent")),
        (.character("f", command: true), String(localized: "Find")),
        (.character("d", command: true, shift: true), String(localized: "Duplicate Line")),
        (.character("k", command: true, shift: true), String(localized: "Delete Line")),
        (.special(.space, control: true), String(localized: "Show Completions")),
        (.special(.upArrow, option: true), String(localized: "Move Line Up")),
        (.special(.downArrow, option: true), String(localized: "Move Line Down"))
    ]

    /// App-level shortcuts that are wired directly in the menu and are not
    /// customizable: tab selection (Cmd+1 through Cmd+9) and editor zoom. These
    /// fire regardless of focus, so a user binding would silently collide.
    static let reservedAppShortcuts: [(key: BoundKey, name: String)] = {
        var shortcuts: [(key: BoundKey, name: String)] = [
            (.character("=", command: true), String(localized: "Zoom In")),
            (.character("-", command: true), String(localized: "Zoom Out"))
        ]
        for number in 1...9 {
            shortcuts.append((
                .character(Character(String(number)), command: true),
                String(format: String(localized: "Select Tab %d"), number)
            ))
        }
        return shortcuts
    }()

    /// The name of a reserved command this combo would shadow: an app-level menu
    /// shortcut (always), or a built-in editor command when the action can fire
    /// while the editor is focused.
    static func reservedConflict(for key: BoundKey, context: ShortcutContext) -> String? {
        if let appName = reservedAppShortcuts.first(where: { $0.key == key })?.name {
            return appName
        }
        guard context == .editor || context == .global else { return nil }
        return editorBuiltIns.first(where: { $0.key == key })?.name
    }
}

// MARK: - Keyboard Settings

/// User's keyboard shortcut customization settings.
/// Only stores overrides; an empty dictionary means all defaults.
struct KeyboardSettings: Codable, Equatable {
    /// User-customized shortcuts (action rawValue -> BoundKey).
    /// Only contains overrides; missing entries use defaults. A renamed action's
    /// stale key becomes a harmless no-op (never matched by any action).
    var shortcuts: [String: BoundKey]

    static let `default` = KeyboardSettings(shortcuts: [:])

    init(shortcuts: [String: BoundKey] = [:]) {
        self.shortcuts = shortcuts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // BoundKey requires `keyCode` and LegacyKeyCombo requires `key`, and
        // neither field exists in the other shape, so the two never decode each
        // other's payload. Modern data is tried first; a legacy file fails that
        // decode and falls through to migration.
        if let modern = try? container.decodeIfPresent([String: BoundKey].self, forKey: .shortcuts) {
            shortcuts = modern ?? [:]
        } else if let legacy = try container.decodeIfPresent([String: LegacyKeyCombo].self, forKey: .shortcuts) {
            shortcuts = legacy.compactMapValues { $0.migrated() }
        } else {
            shortcuts = [:]
        }
    }

    /// Get the effective shortcut for an action (user override or default).
    /// Returns nil if the user explicitly cleared the shortcut.
    func shortcut(for action: ShortcutAction) -> BoundKey? {
        if let override = shortcuts[action.rawValue] {
            return override
        }
        return Self.defaultShortcuts[action]
    }

    func isCustomized(_ action: ShortcutAction) -> Bool {
        shortcuts[action.rawValue] != nil
    }

    /// Find a conflicting action for the given combo within an overlapping
    /// context, excluding the specified action.
    func findConflict(for key: BoundKey, excluding action: ShortcutAction) -> ShortcutAction? {
        guard !key.isCleared else { return nil }
        for other in ShortcutAction.allCases where other != action {
            guard action.context.overlaps(other.context),
                  let otherKey = shortcut(for: other), !otherKey.isCleared,
                  otherKey == key else { continue }
            return other
        }
        return nil
    }

    mutating func setShortcut(_ key: BoundKey, for action: ShortcutAction) {
        shortcuts[action.rawValue] = key
    }

    /// Clear a shortcut so the action has no binding.
    mutating func clearShortcut(for action: ShortcutAction) {
        shortcuts[action.rawValue] = BoundKey.cleared
    }

    /// Reset a specific action to its default shortcut.
    mutating func resetToDefault(for action: ShortcutAction) {
        shortcuts.removeValue(forKey: action.rawValue)
    }

    /// Drop overrides that can never dispatch (bare keys on menu-driven actions),
    /// reverting them to their default. Cleared and unknown overrides are kept.
    func sanitized() -> KeyboardSettings {
        var cleaned = shortcuts
        for (rawValue, key) in shortcuts {
            guard let action = ShortcutAction(rawValue: rawValue), !key.isCleared else { continue }
            if !key.hasModifier, !action.allowsBareKey, !key.isFunctionKey {
                cleaned.removeValue(forKey: rawValue)
            }
        }
        return KeyboardSettings(shortcuts: cleaned)
    }

    /// Build a SwiftUI KeyboardShortcut for the given action's menu item.
    /// Returns nil when the shortcut is cleared, has no representable key, or is a
    /// bare (modifier-less) key. Bare keys dispatch through the responder chain in
    /// the focused view, not through a global menu key-equivalent.
    func keyboardShortcut(for action: ShortcutAction) -> KeyboardShortcut? {
        guard let key = shortcut(for: action), !key.isCleared, key.hasModifier || key.isFunctionKey,
              let equivalent = key.swiftUIKeyEquivalent else {
            return nil
        }
        return KeyboardShortcut(equivalent, modifiers: key.eventModifiers)
    }

    /// A tooltip/help string that appends the action's resolved shortcut, e.g.
    /// "Switch Connection (⌃⌘C)". Returns just the label when the shortcut is
    /// cleared or unset. Reflects user overrides because it resolves through
    /// `shortcut(for:)`.
    func shortcutHint(_ label: String, for action: ShortcutAction) -> String {
        guard let key = shortcut(for: action), !key.isCleared else { return label }
        return "\(label) (\(key.displayString))"
    }

    // MARK: - Default Shortcuts

    /// Default shortcuts, applied when the user has no override. An action absent
    /// from this map has no default and shows as unassigned until the user binds it.
    static let defaultShortcuts: [ShortcutAction: BoundKey] = [
        // Connections
        .newConnection: .character("n", command: true),
        .openDatabase: .character("k", command: true),
        .switchConnection: .character("c", command: true, control: true),

        // Editor & Query
        .openFile: .character("o", command: true),
        .saveChanges: .character("s", command: true),
        .saveAs: .character("s", command: true, shift: true),
        .executeQuery: .special(.return, command: true),
        .executeAllStatements: .special(.return, command: true, shift: true),
        .cancelQuery: .character(".", command: true),
        .explainQuery: .character("e", command: true, option: true),
        .formatQuery: .character("l", command: true, shift: true),
        .previewSQL: .character("p", command: true, shift: true),
        .findNext: .character("g", command: true),
        .findPrevious: .character("g", command: true, shift: true),
        .aiExplainQuery: .character("l", command: true),
        .aiOptimizeQuery: .character("l", command: true, option: true),
        .export: .character("e", command: true, shift: true),
        .importData: .character("i", command: true, shift: true),

        // Data Grid
        .undo: .character("z", command: true),
        .redo: .character("z", command: true, shift: true),
        .cut: .character("x", command: true),
        .copy: .character("c", command: true),
        .copyRowsExplicit: .character("c", command: true, shift: true),
        .copyWithHeaders: .character("c", command: true, option: true),
        .copyAsJson: .character("j", command: true, option: true),
        .paste: .character("v", command: true),
        .delete: .special(.delete, command: true),
        .selectAll: .character("a", command: true),
        .clearSelection: .special(.escape),
        .addRow: .character("n", command: true, shift: true),
        .duplicateRow: .character("d", command: true, shift: true),
        .truncateTable: .special(.delete, option: true),
        .previewFKReference: .special(.space),
        .saveAsFavorite: .character("d", command: true),
        .previousPage: .character("[", command: true),
        .nextPage: .character("]", command: true),
        .firstPage: .special(.upArrow, command: true, option: true),
        .lastPage: .special(.downArrow, command: true, option: true),
        .refresh: .character("r", command: true),

        // Navigation
        .newTab: .character("t", command: true),
        .closeTab: .character("w", command: true),
        .quickSwitcher: .character("o", command: true, shift: true),
        .toggleTableBrowser: .character("0", command: true),
        .toggleInspector: .character("i", command: true, option: true),
        .toggleFilters: .character("f", command: true),
        .toggleHistory: .character("y", command: true),
        .toggleResults: .character("r", command: true, option: true),
        .previousResultTab: .character("[", command: true, option: true),
        .nextResultTab: .character("]", command: true, option: true),
        .closeResultTab: .character("w", command: true, shift: true),
        .focusSidebarSearch: .character("f", command: true, option: true),
        .showSidebarTables: .character("1", command: true, option: true),
        .showSidebarFavorites: .character("2", command: true, option: true),
        .showPreviousTab: .character("[", command: true, shift: true),
        .showNextTab: .character("]", command: true, shift: true)
    ]
}

// MARK: - Legacy Migration

/// The pre-keyCode stored shape of a shortcut. Used only to migrate persisted
/// settings to BoundKey.
private struct LegacyKeyCombo: Codable {
    let key: String
    var command = false
    var shift = false
    var option = false
    var control = false
    var isSpecialKey = false

    func migrated() -> BoundKey? {
        BoundKey(
            legacyKey: key,
            isSpecialKey: isSpecialKey,
            command: command,
            shift: shift,
            option: option,
            control: control
        )
    }
}
