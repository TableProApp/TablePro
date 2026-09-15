//
//  DataSyncTransactionality.swift
//  TablePro
//

import Foundation

internal enum DataSyncTransactionality {
    internal static func needsStorageEngines(_ databaseType: DatabaseType) -> Bool {
        switch databaseType {
        case .mysql, .mariadb:
            return true
        default:
            return false
        }
    }

    internal static func cannotRollBack(storageEngine: String?, databaseType: DatabaseType) -> Bool {
        guard needsStorageEngines(databaseType), let storageEngine, !storageEngine.isEmpty else { return false }
        return !transactionalEngines.contains(storageEngine.lowercased())
    }

    private static let transactionalEngines: Set<String> = [
        "innodb", "xtradb", "ndb", "ndbcluster", "tokudb", "rocksdb"
    ]
}
