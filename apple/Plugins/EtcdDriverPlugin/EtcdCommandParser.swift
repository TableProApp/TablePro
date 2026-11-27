//
//  EtcdCommandParser.swift
//  TablePro
//

import Foundation
import os
import TableProEtcdCore
import TableProPluginKit

enum EtcdOperation {
    // KV
    case get(key: Data, prefix: Bool, limit: Int64?, keysOnly: Bool, sortOrder: EtcdSortOrder?, sortTarget: EtcdSortTarget?)
    case put(key: Data, value: Data, leaseId: Int64?)
    // Not etcdctl verbs. A put that refuses an existing key, and a rename that refuses a taken name.
    case create(key: Data, value: Data, leaseId: Int64?)
    case move(from: Data, to: Data, value: Data, leaseId: Int64?, modRevision: Int64?)
    case del(key: Data, prefix: Bool)
    case watch(key: Data, prefix: Bool, timeout: TimeInterval)

    // Lease
    case leaseGrant(ttl: Int64)
    case leaseRevoke(leaseId: Int64)
    case leaseTimetolive(leaseId: Int64, keys: Bool)
    case leaseList
    case leaseKeepAlive(leaseId: Int64)

    // Cluster
    case memberList
    case endpointStatus
    case endpointHealth

    // Maintenance
    case compaction(revision: Int64, physical: Bool)

    // Auth
    case authEnable
    case authDisable
    case userAdd(name: String, password: String?)
    case userDelete(name: String)
    case userList
    case roleAdd(name: String)
    case roleDelete(name: String)
    case roleList
    case userGrantRole(user: String, role: String)
    case userRevokeRole(user: String, role: String)

    // Generic fallback
    case unknown(command: String, args: [String])
}

enum EtcdOperationTier {
    case read, write, destructive
}

extension EtcdOperation {
    // One table for the host's classifier and the driver's own check. Nil for a command the driver does not run.
    var tier: EtcdOperationTier? {
        switch self {
        case .get, .watch, .leaseTimetolive, .leaseList, .memberList, .endpointStatus, .endpointHealth,
             .userList, .roleList:
            return .read
        case .put, .create, .leaseGrant, .leaseKeepAlive, .authEnable, .userAdd, .roleAdd,
             .userGrantRole, .userRevokeRole:
            return .write
        // One key by name is a row change, as a keyed DELETE is. A prefix can take every key.
        case .del(_, let prefix):
            return prefix ? .destructive : .write
        // A move takes the key away from its name.
        case .move, .compaction, .leaseRevoke, .authDisable, .userDelete, .roleDelete:
            return .destructive
        case .unknown:
            return nil
        }
    }

    func refusal(readOnly: Bool, allowsDestructive: Bool) -> EtcdStatementRefusal? {
        switch tier {
        case .read, nil:
            return nil
        case .write:
            return readOnly ? .writeWhileReadOnly(commandName) : nil
        case .destructive:
            if readOnly { return .writeWhileReadOnly(commandName) }
            return allowsDestructive ? nil : .destructiveNotApproved(commandName)
        }
    }

    private var commandName: String {
        switch self {
        case .get: return "get"
        case .put: return "put"
        case .create: return "create"
        case .move: return "mv"
        case .del: return "del"
        case .watch: return "watch"
        case .leaseGrant: return "lease grant"
        case .leaseRevoke: return "lease revoke"
        case .leaseTimetolive: return "lease timetolive"
        case .leaseList: return "lease list"
        case .leaseKeepAlive: return "lease keep-alive"
        case .memberList: return "member list"
        case .endpointStatus: return "endpoint status"
        case .endpointHealth: return "endpoint health"
        case .compaction: return "compaction"
        case .authEnable: return "auth enable"
        case .authDisable: return "auth disable"
        case .userAdd: return "user add"
        case .userDelete: return "user delete"
        case .userList: return "user list"
        case .roleAdd: return "role add"
        case .roleDelete: return "role delete"
        case .roleList: return "role list"
        case .userGrantRole: return "user grant-role"
        case .userRevokeRole: return "user revoke-role"
        case .unknown(let command, _): return command
        }
    }
}

enum EtcdStatementRefusal: Error, Equatable {
    case writeWhileReadOnly(String)
    case destructiveNotApproved(String)
}

extension EtcdStatementRefusal: PluginDriverError {
    var pluginErrorMessage: String {
        switch self {
        case .writeWhileReadOnly(let command):
            return String(format: String(localized: "Refused %@: this statement ran as a read."), command)
        case .destructiveNotApproved(let command):
            return String(format: String(localized: "Refused %@: deleting data was not approved for this statement."), command)
        }
    }
}

enum EtcdSortOrder: String {
    case ascend = "ASCEND"
    case descend = "DESCEND"
}

enum EtcdSortTarget: String {
    case key = "KEY"
    case version = "VERSION"
    case createRevision = "CREATE"
    case modRevision = "MOD"
    case value = "VALUE"
}

enum EtcdParseError: Error {
    case emptySyntax
    case unknownCommand(String)
    case missingArgument(String)
    case invalidArgument(String)
}

extension EtcdParseError: PluginDriverError {
    var pluginErrorMessage: String {
        switch self {
        case .emptySyntax: return String(localized: "Empty etcd command")
        case .unknownCommand(let cmd): return String(format: String(localized: "Unknown command: %@"), cmd)
        case .missingArgument(let msg): return String(format: String(localized: "Missing argument: %@"), msg)
        case .invalidArgument(let msg): return String(format: String(localized: "Invalid argument: %@"), msg)
        }
    }
}

struct EtcdCommandParser {
    private static let logger = Logger(subsystem: "com.TablePro", category: "EtcdCommandParser")

    static let defaultWatchTimeout: TimeInterval = 30
    static let maximumWatchTimeout: TimeInterval = 3_000

    // MARK: - Public API

    static func parse(_ input: String) throws -> EtcdOperation {
        let trimmed = EtcdCommandText.trimmed(input)
        guard let command = commandName(trimmed) else { throw EtcdParseError.emptySyntax }
        let arguments = trimmed.unicodeScalars.drop(while: { !EtcdCommandText.isBlank($0) })
        let remaining = EtcdCommandText.tokenize(String(arguments))
        let words = remaining.map(\.text)

        switch command {
        case "get": return try parseGet(remaining)
        case "put": return try parsePut(remaining)
        case "create": return try parseCreate(remaining)
        case "mv": return try parseMove(remaining)
        case "del", "delete": return try parseDel(remaining)
        case "watch": return try parseWatch(remaining)
        case "lease": return try parseLease(remaining)
        case "member": return try parseMember(words)
        case "endpoint": return try parseEndpoint(words)
        case "compaction": return try parseCompaction(remaining)
        case "auth": return try parseAuth(words)
        case "user": return try parseUser(words)
        case "role": return try parseRole(words)
        default: return .unknown(command: command, args: words)
        }
    }

    static func commandName(_ input: String) -> String? {
        // A verb stays literal so a registry driver cannot reinterpret an older host's command.
        let word = EtcdCommandText.trimmed(input).unicodeScalars.prefix { !EtcdCommandText.isBlank($0) }
        return word.isEmpty ? nil : String(word).lowercased()
    }

    // MARK: - KV Commands

    private static func parseGet(_ tokens: [EtcdCommandToken]) throws -> EtcdOperation {
        var flags = ParsedFlags()
        let positional = flags.parse(from: tokens)

        guard let key = positional.first?.bytes else {
            throw EtcdParseError.missingArgument("get requires a key")
        }

        let prefix = flags.has("prefix")
        let keysOnly = flags.has("keys-only")

        var limit: Int64?
        if let limitStr = flags.value(for: "limit") {
            guard let parsed = Int64(limitStr) else {
                throw EtcdParseError.invalidArgument("--limit must be an integer")
            }
            limit = parsed
        }

        var sortOrder: EtcdSortOrder?
        if let orderStr = flags.value(for: "order") {
            guard let parsed = EtcdSortOrder(rawValue: orderStr.uppercased()) else {
                throw EtcdParseError.invalidArgument("--order must be ASCEND or DESCEND")
            }
            sortOrder = parsed
        }

        var sortTarget: EtcdSortTarget?
        if let sortByStr = flags.value(for: "sort-by") {
            guard let parsed = EtcdSortTarget(rawValue: sortByStr.uppercased()) else {
                throw EtcdParseError.invalidArgument("--sort-by must be KEY, VERSION, CREATE, MOD, or VALUE")
            }
            sortTarget = parsed
        }

        return .get(
            key: key,
            prefix: prefix,
            limit: limit,
            keysOnly: keysOnly,
            sortOrder: sortOrder,
            sortTarget: sortTarget
        )
    }

    private static func parsePut(_ tokens: [EtcdCommandToken]) throws -> EtcdOperation {
        var flags = ParsedFlags()
        let positional = flags.parse(from: tokens)

        guard positional.count >= 2 else {
            throw EtcdParseError.missingArgument("put requires key and value")
        }

        let key = positional[0].bytes
        let value = positional[1].bytes

        var leaseId: Int64?
        if let leaseStr = flags.value(for: "lease") {
            leaseId = try parseLeaseId(leaseStr)
        }

        return .put(key: key, value: value, leaseId: leaseId)
    }

    private static func parseCreate(_ tokens: [EtcdCommandToken]) throws -> EtcdOperation {
        var flags = ParsedFlags()
        let positional = flags.parse(from: tokens)
        guard positional.count >= 2 else {
            throw EtcdParseError.missingArgument("create requires key and value")
        }
        return .create(
            key: positional[0].bytes,
            value: positional[1].bytes,
            leaseId: try flags.value(for: "lease").map(parseLeaseId)
        )
    }

    private static func parseMove(_ tokens: [EtcdCommandToken]) throws -> EtcdOperation {
        var flags = ParsedFlags()
        let positional = flags.parse(from: tokens)
        guard positional.count >= 3 else {
            throw EtcdParseError.missingArgument("mv requires the key, its new name and the value")
        }
        var modRevision: Int64?
        if let text = flags.value(for: "mod-rev") {
            guard let parsed = Int64(text) else {
                throw EtcdParseError.invalidArgument("--mod-rev must be an integer")
            }
            modRevision = parsed
        }
        return .move(
            from: positional[0].bytes,
            to: positional[1].bytes,
            value: positional[2].bytes,
            leaseId: try flags.value(for: "lease").map(parseLeaseId),
            modRevision: modRevision
        )
    }

    private static func parseDel(_ tokens: [EtcdCommandToken]) throws -> EtcdOperation {
        var flags = ParsedFlags()
        let positional = flags.parse(from: tokens)

        guard let key = positional.first?.bytes else {
            throw EtcdParseError.missingArgument("del requires a key")
        }
        // etcdctl deletes a range for a range end, `--from-key` or `--prefix=true`, which `.del` cannot carry.
        guard positional.count == 1, !flags.has("from-key"), flags.value(for: "from-key") == nil,
              flags.value(for: "prefix") == nil
        else {
            throw EtcdParseError.invalidArgument("del takes one key, or a prefix with --prefix")
        }

        return .del(key: key, prefix: flags.has("prefix"))
    }

    private static func parseWatch(_ tokens: [EtcdCommandToken]) throws -> EtcdOperation {
        var flags = ParsedFlags()
        let positional = flags.parse(from: tokens)

        guard let key = positional.first?.bytes else {
            throw EtcdParseError.missingArgument("watch requires a key")
        }

        let prefix = flags.has("prefix")

        var timeout = Self.defaultWatchTimeout
        if let timeoutStr = flags.value(for: "timeout") {
            guard let parsed = TimeInterval(timeoutStr), parsed.isFinite else {
                throw EtcdParseError.invalidArgument("--timeout must be a number")
            }
            guard parsed >= 0, parsed <= Self.maximumWatchTimeout else {
                throw EtcdParseError.invalidArgument(
                    "--timeout must be between 0 and \(Int(Self.maximumWatchTimeout)) seconds"
                )
            }
            timeout = parsed
        }

        return .watch(key: key, prefix: prefix, timeout: timeout)
    }

    // MARK: - Lease Commands

    private static func parseLease(_ tokens: [EtcdCommandToken]) throws -> EtcdOperation {
        guard let subcommand = tokens.first?.text else {
            throw EtcdParseError.missingArgument("lease requires a subcommand (grant, revoke, timetolive, list, keep-alive)")
        }

        let args = tokens.dropFirst().map(\.text)

        switch subcommand.lowercased() {
        case "grant":
            guard let ttlStr = args.first, let ttl = Int64(ttlStr) else {
                throw EtcdParseError.missingArgument("lease grant requires a TTL (integer seconds)")
            }
            return .leaseGrant(ttl: ttl)

        case "revoke":
            guard let idStr = args.first else {
                throw EtcdParseError.missingArgument("lease revoke requires a lease ID")
            }
            let leaseId = try parseLeaseId(idStr)
            return .leaseRevoke(leaseId: leaseId)

        case "timetolive":
            guard let idStr = args.first else {
                throw EtcdParseError.missingArgument("lease timetolive requires a lease ID")
            }
            let leaseId = try parseLeaseId(idStr)
            var flags = ParsedFlags()
            _ = flags.parse(from: Array(tokens.dropFirst(2)))
            let keys = flags.has("keys")
            return .leaseTimetolive(leaseId: leaseId, keys: keys)

        case "list":
            return .leaseList

        case "keep-alive":
            guard let idStr = args.first else {
                throw EtcdParseError.missingArgument("lease keep-alive requires a lease ID")
            }
            let leaseId = try parseLeaseId(idStr)
            return .leaseKeepAlive(leaseId: leaseId)

        default:
            throw EtcdParseError.unknownCommand("lease \(subcommand)")
        }
    }

    // MARK: - Cluster Commands

    private static func parseMember(_ tokens: [String]) throws -> EtcdOperation {
        guard let subcommand = tokens.first else {
            throw EtcdParseError.missingArgument("member requires a subcommand (list)")
        }

        switch subcommand.lowercased() {
        case "list":
            return .memberList
        default:
            throw EtcdParseError.unknownCommand("member \(subcommand)")
        }
    }

    private static func parseEndpoint(_ tokens: [String]) throws -> EtcdOperation {
        guard let subcommand = tokens.first else {
            throw EtcdParseError.missingArgument("endpoint requires a subcommand (status, health)")
        }

        switch subcommand.lowercased() {
        case "status":
            return .endpointStatus
        case "health":
            return .endpointHealth
        default:
            throw EtcdParseError.unknownCommand("endpoint \(subcommand)")
        }
    }

    // MARK: - Maintenance Commands

    private static func parseCompaction(_ tokens: [EtcdCommandToken]) throws -> EtcdOperation {
        var flags = ParsedFlags()
        let positional = flags.parse(from: tokens)

        guard let revisionStr = positional.first?.text, let revision = Int64(revisionStr) else {
            throw EtcdParseError.missingArgument("compaction requires a revision (integer)")
        }

        let physical = flags.has("physical")
        return .compaction(revision: revision, physical: physical)
    }

    // MARK: - Auth Commands

    private static func parseAuth(_ tokens: [String]) throws -> EtcdOperation {
        guard let subcommand = tokens.first else {
            throw EtcdParseError.missingArgument("auth requires a subcommand (enable, disable)")
        }

        switch subcommand.lowercased() {
        case "enable":
            return .authEnable
        case "disable":
            return .authDisable
        default:
            throw EtcdParseError.unknownCommand("auth \(subcommand)")
        }
    }

    // MARK: - User Commands

    private static func parseUser(_ tokens: [String]) throws -> EtcdOperation {
        guard let subcommand = tokens.first else {
            throw EtcdParseError.missingArgument("user requires a subcommand (add, delete, list, grant-role, revoke-role)")
        }

        let args = Array(tokens.dropFirst())

        switch subcommand.lowercased() {
        case "add":
            guard let name = args.first else {
                throw EtcdParseError.missingArgument("user add requires a username")
            }
            let password = args.count >= 2 ? args[1] : nil
            return .userAdd(name: name, password: password)

        case "delete":
            guard let name = args.first else {
                throw EtcdParseError.missingArgument("user delete requires a username")
            }
            return .userDelete(name: name)

        case "list":
            return .userList

        case "grant-role":
            guard args.count >= 2 else {
                throw EtcdParseError.missingArgument("user grant-role requires a username and role")
            }
            return .userGrantRole(user: args[0], role: args[1])

        case "revoke-role":
            guard args.count >= 2 else {
                throw EtcdParseError.missingArgument("user revoke-role requires a username and role")
            }
            return .userRevokeRole(user: args[0], role: args[1])

        default:
            throw EtcdParseError.unknownCommand("user \(subcommand)")
        }
    }

    // MARK: - Role Commands

    private static func parseRole(_ tokens: [String]) throws -> EtcdOperation {
        guard let subcommand = tokens.first else {
            throw EtcdParseError.missingArgument("role requires a subcommand (add, delete, list)")
        }

        let args = Array(tokens.dropFirst())

        switch subcommand.lowercased() {
        case "add":
            guard let name = args.first else {
                throw EtcdParseError.missingArgument("role add requires a role name")
            }
            return .roleAdd(name: name)

        case "delete":
            guard let name = args.first else {
                throw EtcdParseError.missingArgument("role delete requires a role name")
            }
            return .roleDelete(name: name)

        case "list":
            return .roleList

        default:
            throw EtcdParseError.unknownCommand("role \(subcommand)")
        }
    }

    // MARK: - Lease ID Parsing

    static func parseLeaseId(_ string: String) throws -> Int64 {
        if string.hasPrefix("0x") || string.hasPrefix("0X") {
            let hexStr = String(string.dropFirst(2))
            guard let value = Int64(hexStr, radix: 16) else {
                throw EtcdParseError.invalidArgument("Invalid hex lease ID: \(string)")
            }
            return value
        }

        let containsHexChars = string.contains(where: { "abcdefABCDEF".contains($0) })
        if containsHexChars {
            guard let value = Int64(string, radix: 16) else {
                throw EtcdParseError.invalidArgument("Invalid hex lease ID: \(string)")
            }
            return value
        }

        guard let value = Int64(string) else {
            throw EtcdParseError.invalidArgument("Invalid lease ID: \(string)")
        }
        return value
    }

}

// MARK: - Flag Parsing

private struct ParsedFlags {
    private static let flagsTakingValue: Set<String> = [
        "cacert", "cert", "command-timeout", "consistency", "dial-timeout", "discovery-srv",
        "discovery-srv-name", "endpoints", "keepalive-time", "keepalive-timeout", "key", "lease",
        "limit", "max-create-rev", "max-mod-rev", "min-create-rev", "min-mod-rev", "order",
        "password", "rev", "sort-by", "timeout", "user", "write-out"
    ]

    private var booleanFlags: Set<String> = []
    private var valueFlags: [String: String] = [:]

    // etcdctl reads every token after a bare "--" as an argument, so a key may start with "--".
    mutating func parse(from tokens: [EtcdCommandToken]) -> [EtcdCommandToken] {
        var positional: [EtcdCommandToken] = []
        var index = 0

        while index < tokens.count {
            let token = tokens[index].text
            if token == EtcdCommandText.endOfFlags {
                positional += tokens[(index + 1)...]
                break
            }
            if token.hasPrefix(EtcdCommandText.endOfFlags) {
                let flagContent = String(token.dropFirst(EtcdCommandText.endOfFlags.count))
                if let equalsIndex = flagContent.firstIndex(of: "=") {
                    let key = String(flagContent[flagContent.startIndex..<equalsIndex])
                    let value = String(flagContent[flagContent.index(after: equalsIndex)...])
                    valueFlags[key] = value
                } else if Self.flagsTakingValue.contains(flagContent), index + 1 < tokens.count,
                          !tokens[index + 1].text.hasPrefix(EtcdCommandText.endOfFlags) {
                    valueFlags[flagContent] = tokens[index + 1].text
                    index += 1
                } else {
                    booleanFlags.insert(flagContent)
                }
            } else {
                positional.append(tokens[index])
            }

            index += 1
        }

        return positional
    }

    func has(_ flag: String) -> Bool {
        booleanFlags.contains(flag)
    }

    func value(for flag: String) -> String? {
        valueFlags[flag]
    }
}
