//
//  DatabaseConnection+RedisDatabaseIndex.swift
//  TablePro
//

import Foundation

extension DatabaseConnection {
    private static let redisModeFieldId = "redisMode"
    private static let redisClusterMode = "cluster"

    /// The database a Redis connection opens on. A cluster always starts on database 0, whatever a
    /// Database Index field left over from a Standalone setup still holds, because the field is
    /// hidden in Cluster mode and nothing on screen would say where that value came from.
    var redisDatabaseIndex: Int {
        isRedisCluster ? 0 : configuredRedisDatabaseIndex
    }

    /// The index the connection names, read the way the Redis plugin and the iOS app read it: the
    /// Database Index field, then the value saved before that field existed, then the database
    /// name, where a synced `db4` means 4.
    var configuredRedisDatabaseIndex: Int {
        additionalFields[RedisDatabaseIndex.fieldName].flatMap(RedisDatabaseIndex.parse)
            ?? redisDatabase
            ?? RedisDatabaseIndex.parse(database)
            ?? 0
    }

    func databaseIndex(selectedBy fieldId: String) -> Int {
        if fieldId == RedisDatabaseIndex.fieldName { return redisDatabaseIndex }
        return additionalFields[fieldId].flatMap(RedisDatabaseIndex.parse)
            ?? RedisDatabaseIndex.parse(database)
            ?? 0
    }

    private var isRedisCluster: Bool {
        let mode = additionalFields[Self.redisModeFieldId] ?? ""
        return mode.trimmingCharacters(in: .whitespaces).lowercased() == Self.redisClusterMode
    }
}
