//
//  SQLFavoriteScopeRule.swift
//  TablePro
//

import Foundation
import TableProImport

internal enum SQLFavoriteScopeRule {
    internal static func folder(_ folderConnectionId: UUID?, canHold recordConnectionId: UUID?) -> Bool {
        SavedQueryScopeRule.folder(folderConnectionId, canHold: recordConnectionId)
    }
}
