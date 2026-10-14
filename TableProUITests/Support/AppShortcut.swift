import XCTest

// The app's default key equivalents (KeyboardShortcutModels.defaultShortcuts). A key press reaches the
// command directly; a menu click pays XCUITest's menu traversal, which can stall ten seconds.
internal enum AppShortcut {
    case newConnection
    case settings
    case openQuickly
    case switchConnection
    case newTab
    case closeTab
    case reopenClosedTab
    case recentTab
    case runQuery
    case runAllStatements
    case explainQuery
    case pinResult
    case save
    case undo
    case selectAll
    case addRow
    case deleteRow
    case refresh
    case export
    case toggleFilters
    case toggleHistory
    case toggleInspector
    case toggleAgentMode
    case focusObjectList
    case focusSidebarFilter
    case zoomIn

    fileprivate var chord: (key: String, modifiers: XCUIElement.KeyModifierFlags) {
        switch self {
        case .newConnection: ("n", .command)
        case .settings: (",", .command)
        case .openQuickly: ("o", [.command, .shift])
        case .switchConnection: ("c", [.command, .control])
        case .newTab: ("t", .command)
        case .closeTab: ("w", .command)
        case .reopenClosedTab: ("t", [.command, .shift])
        case .recentTab: (XCUIKeyboardKey.tab.rawValue, .control)
        case .runQuery: (XCUIKeyboardKey.return.rawValue, .command)
        case .runAllStatements: (XCUIKeyboardKey.return.rawValue, [.command, .shift])
        case .explainQuery: ("e", [.command, .option])
        case .pinResult: ("p", [.command, .option])
        case .save: ("s", .command)
        case .undo: ("z", .command)
        case .selectAll: ("a", .command)
        case .addRow: ("n", [.command, .shift])
        case .deleteRow: (XCUIKeyboardKey.delete.rawValue, .command)
        case .refresh: ("r", .command)
        case .export: ("e", [.command, .shift])
        case .toggleFilters: ("f", [.command, .shift])
        case .toggleHistory: ("y", .command)
        case .toggleInspector: ("i", [.command, .option])
        case .toggleAgentMode: ("a", [.command, .shift, .option])
        case .focusObjectList: ("l", [.command, .option, .control])
        case .focusSidebarFilter: ("f", [.command, .option, .control])
        case .zoomIn: ("=", .command)
        }
    }
}

internal extension XCUIElement {
    /// Sent to the key window, so call it on the app unless the command belongs to a focused element.
    func typeShortcut(_ shortcut: AppShortcut) {
        typeKey(shortcut.chord.key, modifierFlags: shortcut.chord.modifiers)
    }
}
