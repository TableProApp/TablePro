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
        ConnectionField(
            id: "redisSeparator",
            label: String(localized: "Key Separator"),
            defaultValue: ":",
            fieldType: .text,
            section: .advanced
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
    static let tableEntityName = "Databases"
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
            // Key commands
            CompletionEntry(label: "GET", insertText: "GET"),
            CompletionEntry(label: "SET", insertText: "SET"),
            CompletionEntry(label: "DEL", insertText: "DEL"),
            CompletionEntry(label: "EXISTS", insertText: "EXISTS"),
            CompletionEntry(label: "KEYS", insertText: "KEYS"),
            CompletionEntry(label: "GETSET", insertText: "GETSET"),
            CompletionEntry(label: "GETDEL", insertText: "GETDEL"),
            CompletionEntry(label: "GETEX", insertText: "GETEX"),
            CompletionEntry(label: "MGET", insertText: "MGET"),
            CompletionEntry(label: "MSET", insertText: "MSET"),
            CompletionEntry(label: "INCR", insertText: "INCR"),
            CompletionEntry(label: "DECR", insertText: "DECR"),
            CompletionEntry(label: "INCRBY", insertText: "INCRBY"),
            CompletionEntry(label: "DECRBY", insertText: "DECRBY"),
            CompletionEntry(label: "INCRBYFLOAT", insertText: "INCRBYFLOAT"),
            CompletionEntry(label: "APPEND", insertText: "APPEND"),
            CompletionEntry(label: "EXPIRE", insertText: "EXPIRE"),
            CompletionEntry(label: "PEXPIRE", insertText: "PEXPIRE"),
            CompletionEntry(label: "EXPIREAT", insertText: "EXPIREAT"),
            CompletionEntry(label: "PEXPIREAT", insertText: "PEXPIREAT"),
            CompletionEntry(label: "TTL", insertText: "TTL"),
            CompletionEntry(label: "PTTL", insertText: "PTTL"),
            CompletionEntry(label: "PERSIST", insertText: "PERSIST"),
            CompletionEntry(label: "TYPE", insertText: "TYPE"),
            CompletionEntry(label: "RENAME", insertText: "RENAME"),
            CompletionEntry(label: "SCAN", insertText: "SCAN"),

            // Hash commands
            CompletionEntry(label: "HGET", insertText: "HGET"),
            CompletionEntry(label: "HSET", insertText: "HSET"),
            CompletionEntry(label: "HGETALL", insertText: "HGETALL"),
            CompletionEntry(label: "HDEL", insertText: "HDEL"),
            CompletionEntry(label: "HSCAN", insertText: "HSCAN"),

            // List commands
            CompletionEntry(label: "LPUSH", insertText: "LPUSH"),
            CompletionEntry(label: "RPUSH", insertText: "RPUSH"),
            CompletionEntry(label: "LRANGE", insertText: "LRANGE"),
            CompletionEntry(label: "LLEN", insertText: "LLEN"),
            CompletionEntry(label: "LPOP", insertText: "LPOP"),
            CompletionEntry(label: "RPOP", insertText: "RPOP"),
            CompletionEntry(label: "LSET", insertText: "LSET"),
            CompletionEntry(label: "LINSERT", insertText: "LINSERT"),
            CompletionEntry(label: "LREM", insertText: "LREM"),
            CompletionEntry(label: "LPOS", insertText: "LPOS"),
            CompletionEntry(label: "LMOVE", insertText: "LMOVE"),

            // Set commands
            CompletionEntry(label: "SADD", insertText: "SADD"),
            CompletionEntry(label: "SMEMBERS", insertText: "SMEMBERS"),
            CompletionEntry(label: "SREM", insertText: "SREM"),
            CompletionEntry(label: "SCARD", insertText: "SCARD"),
            CompletionEntry(label: "SPOP", insertText: "SPOP"),
            CompletionEntry(label: "SRANDMEMBER", insertText: "SRANDMEMBER"),
            CompletionEntry(label: "SMOVE", insertText: "SMOVE"),
            CompletionEntry(label: "SUNION", insertText: "SUNION"),
            CompletionEntry(label: "SINTER", insertText: "SINTER"),
            CompletionEntry(label: "SDIFF", insertText: "SDIFF"),
            CompletionEntry(label: "SUNIONSTORE", insertText: "SUNIONSTORE"),
            CompletionEntry(label: "SINTERSTORE", insertText: "SINTERSTORE"),
            CompletionEntry(label: "SDIFFSTORE", insertText: "SDIFFSTORE"),
            CompletionEntry(label: "SSCAN", insertText: "SSCAN"),

            // Sorted set commands
            CompletionEntry(label: "ZADD", insertText: "ZADD"),
            CompletionEntry(label: "ZRANGE", insertText: "ZRANGE"),
            CompletionEntry(label: "ZREM", insertText: "ZREM"),
            CompletionEntry(label: "ZCARD", insertText: "ZCARD"),
            CompletionEntry(label: "ZSCORE", insertText: "ZSCORE"),
            CompletionEntry(label: "ZRANGEBYSCORE", insertText: "ZRANGEBYSCORE"),
            CompletionEntry(label: "ZREVRANGE", insertText: "ZREVRANGE"),
            CompletionEntry(label: "ZREVRANGEBYSCORE", insertText: "ZREVRANGEBYSCORE"),
            CompletionEntry(label: "ZINCRBY", insertText: "ZINCRBY"),
            CompletionEntry(label: "ZCOUNT", insertText: "ZCOUNT"),
            CompletionEntry(label: "ZRANK", insertText: "ZRANK"),
            CompletionEntry(label: "ZREVRANK", insertText: "ZREVRANK"),
            CompletionEntry(label: "ZPOPMIN", insertText: "ZPOPMIN"),
            CompletionEntry(label: "ZPOPMAX", insertText: "ZPOPMAX"),
            CompletionEntry(label: "ZSCAN", insertText: "ZSCAN"),

            // Stream commands
            CompletionEntry(label: "XRANGE", insertText: "XRANGE"),
            CompletionEntry(label: "XREVRANGE", insertText: "XREVRANGE"),
            CompletionEntry(label: "XLEN", insertText: "XLEN"),
            CompletionEntry(label: "XADD", insertText: "XADD"),
            CompletionEntry(label: "XREAD", insertText: "XREAD"),
            CompletionEntry(label: "XDEL", insertText: "XDEL"),
            CompletionEntry(label: "XTRIM", insertText: "XTRIM"),
            CompletionEntry(label: "XINFO", insertText: "XINFO"),
            CompletionEntry(label: "XGROUP", insertText: "XGROUP"),
            CompletionEntry(label: "XACK", insertText: "XACK"),

            // Server commands
            CompletionEntry(label: "PING", insertText: "PING"),
            CompletionEntry(label: "INFO", insertText: "INFO"),
            CompletionEntry(label: "DBSIZE", insertText: "DBSIZE"),
            CompletionEntry(label: "FLUSHDB", insertText: "FLUSHDB"),
            CompletionEntry(label: "FLUSHALL", insertText: "FLUSHALL"),
            CompletionEntry(label: "SELECT", insertText: "SELECT"),
            CompletionEntry(label: "CONFIG", insertText: "CONFIG"),
            CompletionEntry(label: "AUTH", insertText: "AUTH"),
            CompletionEntry(label: "OBJECT", insertText: "OBJECT"),
            CompletionEntry(label: "MULTI", insertText: "MULTI"),
            CompletionEntry(label: "EXEC", insertText: "EXEC"),
            CompletionEntry(label: "DISCARD", insertText: "DISCARD"),
        ]
    }

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        RedisPluginDriver(config: config)
    }
}
