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

    static func openKey(_ key: String, keyType: String?) -> String {
        let argument = quoted(key)
        switch keyType?.lowercased() {
        case "hash"?: return "HGETALL \(argument)"
        case "list"?: return "LRANGE \(argument) 0 -1"
        case "set"?: return "SMEMBERS \(argument)"
        case "zset"?: return "ZRANGE \(argument) 0 -1 WITHSCORES"
        case "stream"?: return "XRANGE \(argument) - +"
        default: return "GET \(argument)"
        }
    }

    /// Inside double quotes `redis-cli` decodes `\n`, `\t` and `\xHH`, so a backslash is escaped as
    /// well as the quote. Single quotes cannot carry every key: `'a\'` reads as an unclosed quote.
    private static func quoted(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{07}": result += "\\a"
            default:
                guard scalar.value < 0x20 || scalar.value == 0x7F else {
                    result.unicodeScalars.append(scalar)
                    continue
                }
                result += String(format: "\\x%02x", scalar.value)
            }
        }
        return result + "\""
    }
}
