//
//  PendingChangeKind.swift
//  TablePro
//

import Foundation

/// What the window's Save command would commit, which is also whether it can commit at all.
///
/// One value rather than five booleans read in five places. `updateToolbarPendingState()` folded
/// four of the five sources into `hasPendingChanges` and never read the fifth, so a Users & Roles
/// tab with staged principals left both the toolbar's commit button and Cmd+S dim while
/// `saveChanges()` already carried the branch that would have applied them.
///
/// The tab decides the kind, because two kinds can be staged at once and only one of them is the
/// one the user is looking at. It decides nothing the user reads: the commit control's label is
/// `ToolbarContextResolver.commitVerb(for:)`, from the tab kind alone, because this value comes and
/// goes with every edit and a label that followed it moved the titlebar while the user typed.
internal enum PendingChangeKind: Equatable, Hashable, Sendable {
    case data
    case structure
    case createTable
    case principals
    case file

    /// Nil when nothing is staged for this tab, which is what leaves the commit control dim.
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
            /// A definition that is not yet committable is not a pending change: the tab's own
            /// validity gate is what `hasCreateTablePending` already answers.
            return hasCreateTablePending ? .createTable : nil
        case .usersRoles:
            return hasPrincipalChanges ? .principals : nil
        case .query, .table, .erDiagram, .serverDashboard, .insights, .objectSource:
            return contentKind(
                hasDataChanges: hasDataChanges,
                hasStructureChanges: hasStructureChanges,
                isFileDirty: isFileDirty
            )
        }
    }

    /// Structure outranks data, and data outranks a dirty file, because a structure edit rewrites
    /// the table the staged rows are going into and has to be named first.
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
