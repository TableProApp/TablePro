//
//  SyncScope.swift
//  TablePro
//

import Foundation

enum SyncScope: Equatable {
    case synced
    case deviceLocal
}

extension SyncRecordType {
    var syncScope: SyncScope {
        switch self {
        case .connection, .group, .tag, .settings, .favorite, .favoriteFolder, .tableFavorite, .sshProfile:
            return .synced
        }
    }
}
