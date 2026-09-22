//
//  SQLFavoriteScopeRule.swift
//  TablePro
//

import Foundation

/// The containment rule for saved queries, in one place.
///
/// Scope is a connection id on the record itself, where nil means every connection, and a folder
/// carries one of its own. Nothing used to compare the two, so a global query could be saved into a
/// folder belonging to one connection and then be drawn by no other connection at all.
internal enum SQLFavoriteScopeRule {
    /// Whether a folder is allowed to hold a record, which it is when the folder's scope is no
    /// narrower than the record's. A global folder holds anything; a folder belonging to one
    /// connection holds only that connection's records.
    internal static func folder(_ folderConnectionId: UUID?, canHold recordConnectionId: UUID?) -> Bool {
        folderConnectionId == nil || folderConnectionId == recordConnectionId
    }
}
