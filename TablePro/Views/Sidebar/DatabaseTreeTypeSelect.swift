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

    /// Group rows and status rows have no name a user would type, and returning a string for them
    /// makes type-select land on a row that cannot be opened.
    internal static func matchString(for kind: DatabaseTreeNode.Kind) -> String? {
        switch kind {
        case .recentSection, .status:
            return nil
        case .recentTable(let ref), .table(let ref):
            return ref.table.name
        case .database(let metadata):
            return metadata.name
        case .schema(_, let schema):
            return schema
        case .routine(let ref):
            return ref.routine.name
        }
    }
}
