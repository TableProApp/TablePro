//
//  DatabaseConnection+RedisDatabaseIndex.swift
//  TablePro
//

import Foundation

extension DatabaseConnection {
    private static let redisModeFieldId = "redisMode"
    private static let redisClusterMode = "cluster"

    var redisDatabaseIndex: Int {
        isRedisCluster ? 0 : configuredRedisDatabaseIndex
    }

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
