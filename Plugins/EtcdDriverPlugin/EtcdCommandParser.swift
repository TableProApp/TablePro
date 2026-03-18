//
//  EtcdCommandParser.swift
//  TablePro
//
//  Parses etcdctl-compatible command strings into structured operations.
//  Supports: get, put, del, watch, lease, member, endpoint, compaction, auth, user, role commands.
//

import Foundation
import os
import TableProPluginKit

enum EtcdOperation {
    // KV
    case get(key: String, prefix: Bool, limit: Int64?, keysOnly: Bool, sortOrder: EtcdSortOrder?, sortTarget: EtcdSortTarget?)
    case put(key: String, value: String, leaseId: Int64?)
    case del(key: String, prefix: Bool)
    case watch(key: String, prefix: Bool, timeout: TimeInterval)

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
        case .unknownCommand(let cmd): return String(localized: "Unknown command: \(cmd)")
        case .missingArgument(let msg): return String(localized: "Missing argument: \(msg)")
        case .invalidArgument(let msg): return String(localized: "Invalid argument: \(msg)")
        }
    }
}

struct EtcdCommandParser {
    private static let logger = Logger(subsystem: "com.TablePro", category: "EtcdCommandParser")

    // MARK: - Public API

    static func parse(_ input: String) throws -> EtcdOperation {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EtcdParseError.emptySyntax }

        let tokens = tokenize(trimmed)
        guard let first = tokens.first else { throw EtcdParseError.emptySyntax }

        let command = first.lowercased()
        let remaining = Array(tokens.dropFirst())

        switch command {
        case "get": return try parseGet(remaining)
        case "put": return try parsePut(remaining)
        case "del", "delete": return try parseDel(remaining)
        case "watch": return try parseWatch(remaining)
        case "lease": return try parseLease(remaining)
        case "member": return try parseMember(remaining)
        case "endpoint": return try parseEndpoint(remaining)
        case "compaction": return try parseCompaction(remaining)
        case "auth": return try parseAuth(remaining)
        case "user": return try parseUser(remaining)
        case "role": return try parseRole(remaining)
        default: return .unknown(command: command, args: remaining)
        }
    }

    // MARK: - KV Commands

    private static func parseGet(_ tokens: [String]) throws -> EtcdOperation {
        var flags = ParsedFlags()
        let positional = flags.parse(from: tokens)

        guard let key = positional.first else {
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

    private static func parsePut(_ tokens: [String]) throws -> EtcdOperation {
        var flags = ParsedFlags()
        let positional = flags.parse(from: tokens)

        guard positional.count >= 2 else {
            throw EtcdParseError.missingArgument("put requires key and value")
        }

        let key = positional[0]
        let value = positional[1]

        var leaseId: Int64?
        if let leaseStr = flags.value(for: "lease") {
            leaseId = try parseLeaseId(leaseStr)
        }

        return .put(key: key, value: value, leaseId: leaseId)
    }

    private static func parseDel(_ tokens: [String]) throws -> EtcdOperation {
        var flags = ParsedFlags()
        let positional = flags.parse(from: tokens)

        guard let key = positional.first else {
            throw EtcdParseError.missingArgument("del requires a key")
        }

        let prefix = flags.has("prefix")
        return .del(key: key, prefix: prefix)
    }

    private static func parseWatch(_ tokens: [String]) throws -> EtcdOperation {
        var flags = ParsedFlags()
        let positional = flags.parse(from: tokens)

        guard let key = positional.first else {
            throw EtcdParseError.missingArgument("watch requires a key")
        }

        let prefix = flags.has("prefix")

        var timeout: TimeInterval = 30
        if let timeoutStr = flags.value(for: "timeout") {
            guard let parsed = TimeInterval(timeoutStr) else {
                throw EtcdParseError.invalidArgument("--timeout must be a number")
            }
            timeout = parsed
        }

        return .watch(key: key, prefix: prefix, timeout: timeout)
    }

    // MARK: - Lease Commands

    private static func parseLease(_ tokens: [String]) throws -> EtcdOperation {
        guard let subcommand = tokens.first else {
            throw EtcdParseError.missingArgument("lease requires a subcommand (grant, revoke, timetolive, list, keep-alive)")
        }

        let args = Array(tokens.dropFirst())

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
            _ = flags.parse(from: Array(args.dropFirst()))
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

    private static func parseCompaction(_ tokens: [String]) throws -> EtcdOperation {
        var flags = ParsedFlags()
        let positional = flags.parse(from: tokens)

        guard let revisionStr = positional.first, let revision = Int64(revisionStr) else {
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

    // MARK: - Tokenizer

    private static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false
        var quoteChar: Character = "\""
        var escapeNext = false
        var tokenStarted = false

        for char in input {
            if escapeNext {
                tokenStarted = true
                if inQuote {
                    switch char {
                    case "n": current.append("\n")
                    case "r": current.append("\r")
                    case "t": current.append("\t")
                    case "\\": current.append("\\")
                    case "\"": current.append("\"")
                    case "'": current.append("'")
                    default:
                        current.append("\\")
                        current.append(char)
                    }
                } else {
                    // Outside quotes, preserve literal backslash
                    current.append("\\")
                    current.append(char)
                }
                escapeNext = false
                continue
            }

            if char == "\\" {
                if inQuote {
                    escapeNext = true
                } else {
                    // Outside quotes, backslash is literal
                    current.append(char)
                    tokenStarted = true
                }
                continue
            }

            if inQuote {
                if char == quoteChar {
                    inQuote = false
                    tokenStarted = true // preserve empty quoted token
                } else {
                    current.append(char)
                    tokenStarted = true
                }
                continue
            }

            if char == "\"" || char == "'" {
                inQuote = true
                quoteChar = char
                tokenStarted = true
                continue
            }

            if char.isWhitespace {
                if tokenStarted {
                    tokens.append(current)
                    current = ""
                    tokenStarted = false
                }
                continue
            }

            current.append(char)
            tokenStarted = true
        }

        if escapeNext {
            current.append("\\")
            tokenStarted = true
        }

        if tokenStarted {
            tokens.append(current)
        }

        return tokens
    }
}

// MARK: - Flag Parsing

private struct ParsedFlags {
    private var booleanFlags: Set<String> = []
    private var valueFlags: [String: String] = [:]

    mutating func parse(from tokens: [String]) -> [String] {
        var positional: [String] = []
        var index = 0

        while index < tokens.count {
            let token = tokens[index]
            if token.hasPrefix("--") {
                let flagContent = String(token.dropFirst(2))
                if let equalsIndex = flagContent.firstIndex(of: "=") {
                    let key = String(flagContent[flagContent.startIndex..<equalsIndex])
                    let value = String(flagContent[flagContent.index(after: equalsIndex)...])
                    valueFlags[key] = value
                } else if index + 1 < tokens.count, !tokens[index + 1].hasPrefix("--") {
                    valueFlags[flagContent] = tokens[index + 1]
                    index += 1
                } else {
                    booleanFlags.insert(flagContent)
                }
            } else {
                positional.append(token)
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
