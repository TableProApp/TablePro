//
//  RedisPlugin.swift
//  RedisDriverPlugin
//
//  Redis database driver plugin using hiredis (Redis C client library)
//

import Foundation
import os
import TableProPluginKit

// MARK: - Plugin Entry Point

final class RedisPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Redis Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Redis support via hiredis"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "Redis"
    static let databaseDisplayName = "Redis"
    static let iconName = "redis-icon"
    static let defaultPort = 6379
    static let additionalConnectionFields: [ConnectionField] = [
        ConnectionField(
            id: "redisDatabase",
            label: String(localized: "Database Index"),
            defaultValue: "0",
            fieldType: .stepper(range: ConnectionField.IntRange(0...15))
        ),
    ]
    static let additionalDatabaseTypeIds: [String] = []

    // MARK: - UI/Capability Metadata

    static let navigationModel: NavigationModel = .inPlace
    static let pathFieldRole: PathFieldRole = .databaseIndex
    static let postConnectActions: [PostConnectAction] = [.selectDatabaseFromConnectionField(fieldId: "redisDatabase")]
    static let requiresAuthentication = false
    static let urlSchemes: [String] = ["redis"]
    static let brandColorHex = "#DC382D"
    static let queryLanguageName = "Redis CLI"
    static let editorLanguage: EditorLanguage = .bash
    static let supportsForeignKeys = false
    static let supportsSchemaEditing = false
    static let supportsDatabaseSwitching = false
    static let supportsImport = false
    static let tableEntityName = "Keys"
    static let supportsForeignKeyDisable = false
    static let supportsReadOnlyMode = false
    static let databaseGroupingStrategy: GroupingStrategy = .flat
    static let defaultGroupName = "db0"
    static let columnTypesByCategory: [String: [String]] = [
        "String": ["string"],
        "List": ["list"],
        "Set": ["set"],
        "Sorted Set": ["zset"],
        "Hash": ["hash"],
        "Stream": ["stream"],
        "HyperLogLog": ["hyperloglog"],
        "Bitmap": ["bitmap"],
        "Geospatial": ["geo"]
    ]

    static let structureColumnFields: [StructureColumnField] = [.name, .type, .nullable]
    static let defaultPrimaryKeyColumn: String? = "Key"

    static let sqlDialect: SQLDialectDescriptor? = nil

    static var statementCompletions: [CompletionEntry] {
        [
            CompletionEntry(label: "GET", insertText: "GET"),
            CompletionEntry(label: "SET", insertText: "SET"),
            CompletionEntry(label: "DEL", insertText: "DEL"),
            CompletionEntry(label: "EXISTS", insertText: "EXISTS"),
            CompletionEntry(label: "KEYS", insertText: "KEYS"),
            CompletionEntry(label: "HGET", insertText: "HGET"),
            CompletionEntry(label: "HSET", insertText: "HSET"),
            CompletionEntry(label: "HGETALL", insertText: "HGETALL"),
            CompletionEntry(label: "HDEL", insertText: "HDEL"),
            CompletionEntry(label: "LPUSH", insertText: "LPUSH"),
            CompletionEntry(label: "RPUSH", insertText: "RPUSH"),
            CompletionEntry(label: "LRANGE", insertText: "LRANGE"),
            CompletionEntry(label: "LLEN", insertText: "LLEN"),
            CompletionEntry(label: "SADD", insertText: "SADD"),
            CompletionEntry(label: "SMEMBERS", insertText: "SMEMBERS"),
            CompletionEntry(label: "SREM", insertText: "SREM"),
            CompletionEntry(label: "SCARD", insertText: "SCARD"),
            CompletionEntry(label: "ZADD", insertText: "ZADD"),
            CompletionEntry(label: "ZRANGE", insertText: "ZRANGE"),
            CompletionEntry(label: "ZREM", insertText: "ZREM"),
            CompletionEntry(label: "ZSCORE", insertText: "ZSCORE"),
            CompletionEntry(label: "EXPIRE", insertText: "EXPIRE"),
            CompletionEntry(label: "TTL", insertText: "TTL"),
            CompletionEntry(label: "PERSIST", insertText: "PERSIST"),
            CompletionEntry(label: "TYPE", insertText: "TYPE"),
            CompletionEntry(label: "SCAN", insertText: "SCAN"),
            CompletionEntry(label: "HSCAN", insertText: "HSCAN"),
            CompletionEntry(label: "SSCAN", insertText: "SSCAN"),
            CompletionEntry(label: "ZSCAN", insertText: "ZSCAN"),
            CompletionEntry(label: "INFO", insertText: "INFO"),
            CompletionEntry(label: "DBSIZE", insertText: "DBSIZE"),
            CompletionEntry(label: "FLUSHDB", insertText: "FLUSHDB"),
            CompletionEntry(label: "SELECT", insertText: "SELECT"),
            CompletionEntry(label: "INCR", insertText: "INCR"),
            CompletionEntry(label: "DECR", insertText: "DECR"),
            CompletionEntry(label: "APPEND", insertText: "APPEND"),
            CompletionEntry(label: "MGET", insertText: "MGET"),
            CompletionEntry(label: "MSET", insertText: "MSET")
        ]
    }

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        RedisPluginDriver(config: config)
    }
}
