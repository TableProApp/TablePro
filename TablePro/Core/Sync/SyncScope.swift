//
//  SyncScope.swift
//  TablePro
//

import Foundation
import TableProSyncTransport

enum SyncScope: Equatable {
    case synced
    case deviceLocal
}

extension SyncRecordType {
    var syncScope: SyncScope {
        switch self {
        case .connection, .group, .tag, .settings, .favorite, .favoriteFolder,
             .tableFavorite, .favoriteDatabase, .sshProfile:
            return .synced
        }
    }
}
