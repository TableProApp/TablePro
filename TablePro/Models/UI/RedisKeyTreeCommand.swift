//
//  RedisKeyTreeCommand.swift
//  TablePro
//

import Foundation

/// The commands the sidebar's key tree sends. Both name what they read explicitly, the database
/// the tree lists and the key a row stands for, so neither depends on where the session was left.
internal enum RedisKeyTreeCommand {
    static func listKeys(inDatabase databaseIndex: Int, limit: Int) -> String {
        "KEYTREE DB \(databaseIndex) LIMIT \(limit)"
    }

    static func openKey(_ key: String, keyType: String?, inDatabase databaseIndex: Int) -> String {
        "DB \(databaseIndex) \(readKey(key, keyType: keyType))"
    }

    private static func readKey(_ key: String, keyType: String?) -> String {
        let argument = RedisArgumentCodec.quotedText(key)
        switch keyType?.lowercased() {
        case "hash"?: return "HGETALL \(argument)"
        case "list"?: return "LRANGE \(argument) 0 -1"
        case "set"?: return "SMEMBERS \(argument)"
        case "zset"?: return "ZRANGE \(argument) 0 -1 WITHSCORES"
        case "stream"?: return "XRANGE \(argument) - +"
        default: return "GET \(argument)"
        }
    }
}
