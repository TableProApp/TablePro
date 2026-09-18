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

    private static func isPlainIdentifier(_ name: String) -> Bool {
        guard let first = name.first, !first.isNumber else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
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
