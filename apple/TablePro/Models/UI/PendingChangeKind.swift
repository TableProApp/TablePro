//
//  PendingChangeKind.swift
//  TablePro
//

import Foundation

// What the window's Save would commit, and whether it can commit at all. The tab decides the kind, since two kinds
// can be staged at once; the commit label comes from the tab kind alone, so it does not move while the user types.
internal enum PendingChangeKind: Equatable, Hashable, Sendable {
    case data
    case structure
    case createTable
    case principals
    case file

    // Nil when nothing is staged for this tab, which leaves the commit control dim.
    internal static func resolve(
        tabType: TabType?,
        hasDataChanges: Bool,
        hasStructureChanges: Bool,
        hasCreateTablePending: Bool,
        hasPrincipalChanges: Bool,
        isFileDirty: Bool
    ) -> PendingChangeKind? {
        guard let tabType else {
            return contentKind(
                hasDataChanges: hasDataChanges,
                hasStructureChanges: hasStructureChanges,
                isFileDirty: isFileDirty
            )
        }
        switch tabType {
        case .createTable:
            // A definition that is not yet committable is not a pending change.
            return hasCreateTablePending ? .createTable : nil
        case .usersRoles:
            return hasPrincipalChanges ? .principals : nil
        case .query, .table, .erDiagram, .serverDashboard, .insights, .tableHealth, .objectSource, .versionHistory,
             .tableListing, .routineDebug, .liveMessages:
            return contentKind(
                hasDataChanges: hasDataChanges,
                hasStructureChanges: hasStructureChanges,
                isFileDirty: isFileDirty
            )
        }
    }

    // Narrower than the commit: a dirty file and staged principals have no SQL to show, and a structure session
    // previews only from its own Structure view, so staged ALTERs behind the Data view leave Preview with nothing.
    internal static func offersPreview(
        of kind: PendingChangeKind?,
        hasDataChanges: Bool,
        previewsSchemaChanges: Bool
    ) -> Bool {
        switch kind {
        case .data, .createTable:
            return true
        case .structure:
            return hasDataChanges || previewsSchemaChanges
        case .principals, .file, nil:
            return false
        }
    }

    // A structure edit rewrites the table the staged rows go into, so it is named before data, and data before a file.
    private static func contentKind(
        hasDataChanges: Bool,
        hasStructureChanges: Bool,
        isFileDirty: Bool
    ) -> PendingChangeKind? {
        if hasStructureChanges { return .structure }
        if hasDataChanges { return .data }
        return isFileDirty ? .file : nil
    }
}
