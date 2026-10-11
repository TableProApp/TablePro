//
//  MongoCollectionAccessor.swift
//  TableProPluginKit
//

import Foundation

/// Spells the shell expression that reaches a collection by name.
///
/// `db.<name>` and `db["<name>"]` both go through the `db` object's property lookup, and in
/// mongosh as in TablePro's own shell that lookup answers a method before a collection. So a
/// collection called `stats` or `version` comes back as a function, and `.find()` on it is a
/// TypeError. `db.getCollection("<name>")` is the one spelling that cannot be shadowed.
public enum MongoCollectionAccessor {
    public static func expression(for name: String) -> String {
        guard isPlainIdentifier(name), !isShadowedByDatabaseMember(name) else {
            return "db.getCollection(\"\(PluginExportUtilities.escapeJSONString(name))\")"
        }
        return "db.\(name)"
    }

    public static func unescape(_ escaped: String) -> String {
        let quoted = Data("\"\(escaped)\"".utf8)
        return (try? JSONDecoder().decode(String.self, from: quoted)) ?? escaped
    }

    public static func isShadowedByDatabaseMember(_ name: String) -> Bool {
        name.hasPrefix("__") || databaseMemberNames.contains(name)
    }

    /// Checked byte by byte, because a `Character` is a whole grapheme cluster: a Unicode Prepend
    /// letter such as U+0D4E joined to a `(` or `;` answers `isLetter` for the pair, and the name
    /// then reached the statement bare, as code. Everything else goes through `getCollection`.
    private static func isPlainIdentifier(_ name: String) -> Bool {
        guard let first = name.utf8.first, !isASCIIDigit(first) else { return false }
        return name.utf8.allSatisfy { isASCIILetter($0) || isASCIIDigit($0) || $0 == UInt8(ascii: "_") }
    }

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A") ... UInt8(ascii: "Z")).contains(byte)
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
    }

    /// Every method mongosh puts on `db`, plus what `Object.prototype` gives any JavaScript value.
    public static let databaseMemberNames: Set<String> = [
        "adminCommand", "aggregate", "auth", "changeUserPassword", "checkMetadataConsistency",
        "commandHelp", "createCollection", "createRole", "createUser", "createView", "currentOp",
        "disableFreeMonitoring", "dropAllRoles", "dropAllUsers", "dropDatabase", "dropRole",
        "dropUser", "enableFreeMonitoring", "fsyncLock", "fsyncUnlock", "getCollection",
        "getCollectionInfos", "getCollectionNames", "getFreeMonitoringStatus", "getLastError",
        "getLastErrorObj", "getLogComponents", "getMongo", "getName", "getProfilingLevel",
        "getProfilingStatus", "getReplicationInfo", "getRole", "getRoles", "getSiblingDB",
        "getUser", "getUsers", "grantPrivilegesToRole", "grantRolesToRole", "grantRolesToUser",
        "hello", "help", "hostInfo", "isMaster", "killOp", "listCommands", "logout",
        "printCollectionStats", "printReplicationInfo", "printSecondaryReplicationInfo",
        "printShardingStatus", "printSlaveReplicationInfo", "removeUser", "revokePrivilegesFromRole",
        "revokeRolesFromRole", "revokeRolesFromUser", "rotateCertificates", "runCommand",
        "serverBuildInfo", "serverCmdLineOpts", "serverStatus", "setLogLevel", "setProfilingLevel",
        "shutdownServer", "sql", "stats", "updateRole", "updateUser", "version", "watch",
        "constructor", "hasOwnProperty", "isPrototypeOf", "propertyIsEnumerable",
        "toLocaleString", "toString", "valueOf"
    ]
}
