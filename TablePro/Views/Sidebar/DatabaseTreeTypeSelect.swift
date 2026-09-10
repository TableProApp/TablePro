//
//  DatabaseTreeTypeSelect.swift
//  TablePro
//

import AppKit

internal enum DatabaseTreeTypeSelect {
    private static let upArrowKeyCode: UInt16 = 126
    private static let downArrowKeyCode: UInt16 = 125

    /// Type-select delivers one selection change per typed letter. Treating every key event as a
    /// deliberate open would fire a query per keystroke, so only the arrow keys, which are how a
    /// list is actually walked, count as navigation.
    internal static func isArrowNavigation(type: NSEvent.EventType, keyCode: UInt16) -> Bool {
        guard type == .keyDown || type == .keyUp else { return false }
        return keyCode == upArrowKeyCode || keyCode == downArrowKeyCode
    }

    /// Reads `keyCode` only once the event is known to be a key event.
    ///
    /// `NSEvent.keyCode` is documented as valid for key-up and key-down alone, and AppKit raises on
    /// anything else. Passing `event.keyCode` as an argument to the test above evaluates it before
    /// the type is checked, so a mouse-driven selection raised from inside the selection-changed
    /// notification. The exception unwound through AppKit's own mouse tracking, which left the
    /// table view's click handling half finished: no open, no mouse up, and a tracking loop that
    /// only ended when the next click arrived.
    internal static func isArrowNavigation(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown || event.type == .keyUp else { return false }
        return isArrowNavigation(type: event.type, keyCode: event.keyCode)
    }

    /// Whether a selection change came from a key the user is holding down.
    ///
    /// Only a repeat is a burst worth coalescing. `NSEvent.keyRepeatInterval` is the user's key
    /// repeat rate from System Settings, up to two seconds at the slowest stop, so charging it to a
    /// single deliberate press left the row highlighted and the table unopened for that whole time.
    internal static func isAutorepeatingArrowNavigation(_ event: NSEvent) -> Bool {
        guard isArrowNavigation(event), event.type == .keyDown else { return false }
        return event.isARepeat
    }

    /// Type-select finds objects, and a section title or a status line is not one. AppKit already
    /// walks past a match it cannot select, so this decides what the search means rather than
    /// keeping the selection off a dead row.
    ///
    /// A container's object group is a selectable row, so it matches on the same title its row
    /// draws. The plugin names the table group, which is why the caller resolves that title rather
    /// than the kind naming itself.
    internal static func matchString(
        for kind: DatabaseTreeNode.Kind,
        tableEntityName: String? = nil
    ) -> String? {
        switch kind {
        case .recentSection, .status, .objectKindSection, .redisKeysSection:
            return nil
        case .containerObjectKindSection(let group):
            return group.kind.title(tableEntityName: tableEntityName)
        case .recentTable(let ref), .table(let ref):
            return ref.table.name
        case .database(let metadata):
            return metadata.name
        case .schema(_, let schema):
            return schema
        case .routine(let ref):
            return ref.routine.name
        case .trigger(let ref):
            return ref.trigger.name
        case .userType(let ref):
            return ref.type.name
        case .hierarchicalSchemaSection(let schema):
            return schema
        case .redisNode(let node):
            return node.displayName
        }
    }
}
