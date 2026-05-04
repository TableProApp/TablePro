//
//  SSHConfigParser.swift
//  TablePro
//

import Darwin
import Foundation
import os

struct SSHConfigEntry: Identifiable, Hashable {
    let id = UUID()
    let host: String
    let hostname: String?
    let port: Int?
    let user: String?
    let identityFiles: [String]
    let identityAgent: String?
    let proxyJump: String?
    let identitiesOnly: Bool?
    let addKeysToAgent: Bool?
    let useKeychain: Bool?

    var displayName: String {
        if let hostname, hostname != host {
            return "\(host) (\(hostname))"
        }
        return host
    }
}

enum SSHConfigParser {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SSHConfigParser")
    private static let maxIncludeDepth = 10

    static let defaultConfigPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".ssh/config").path(percentEncoded: false)

    // MARK: - Public API

    static func parseDocument(path: String = defaultConfigPath) -> SSHConfigDocument {
        var visited = Set<String>()
        var sources: [String] = []
        let blocks = parseFile(path: path, visited: &visited, sources: &sources, depth: 0)
        return SSHConfigDocument(blocks: blocks, sourcePaths: sources)
    }

    static func parse(path: String = defaultConfigPath) -> [SSHConfigEntry] {
        flatten(parseDocument(path: path))
    }

    static func parseContent(_ content: String) -> [SSHConfigEntry] {
        var visited = Set<String>()
        var sources: [String] = []
        let blocks = parseLines(
            content.components(separatedBy: .newlines),
            baseDir: nil,
            visited: &visited,
            sources: &sources,
            depth: 0
        )
        return flatten(SSHConfigDocument(blocks: blocks, sourcePaths: sources))
    }

    static func parseDocumentContent(_ content: String, baseDir: URL? = nil) -> SSHConfigDocument {
        var visited = Set<String>()
        var sources: [String] = []
        let blocks = parseLines(
            content.components(separatedBy: .newlines),
            baseDir: baseDir,
            visited: &visited,
            sources: &sources,
            depth: 0
        )
        return SSHConfigDocument(blocks: blocks, sourcePaths: sources)
    }

    static func findEntry(for host: String, path: String = defaultConfigPath) -> SSHConfigEntry? {
        parse(path: path).first { $0.host.lowercased() == host.lowercased() }
    }

    static func parseProxyJump(_ value: String) -> [SSHJumpHost] {
        let hops = value.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var jumpHosts: [SSHJumpHost] = []

        for hop in hops where !hop.isEmpty {
            var jumpHost = SSHJumpHost()
            var remaining = hop

            if let atIndex = remaining.firstIndex(of: "@") {
                jumpHost.username = String(remaining[remaining.startIndex..<atIndex])
                remaining = String(remaining[remaining.index(after: atIndex)...])
            }

            if remaining.hasPrefix("["), let closeBracket = remaining.firstIndex(of: "]") {
                jumpHost.host = String(remaining[remaining.index(after: remaining.startIndex)..<closeBracket])
                let afterBracket = remaining.index(after: closeBracket)
                if afterBracket < remaining.endIndex,
                   remaining[afterBracket] == ":",
                   let port = Int(String(remaining[remaining.index(after: afterBracket)...])) {
                    jumpHost.port = port
                }
            } else if let colonIndex = remaining.lastIndex(of: ":"),
                      let port = Int(String(remaining[remaining.index(after: colonIndex)...])) {
                jumpHost.host = String(remaining[remaining.startIndex..<colonIndex])
                jumpHost.port = port
            } else {
                jumpHost.host = remaining
            }

            jumpHosts.append(jumpHost)
        }
        return jumpHosts
    }

    // MARK: - File parsing

    private static func parseFile(
        path: String,
        visited: inout Set<String>,
        sources: inout [String],
        depth: Int
    ) -> [SSHConfigBlock] {
        guard depth <= maxIncludeDepth else {
            logger.warning("SSH config Include depth exceeded at: \(path, privacy: .public)")
            return []
        }

        let canonical = (path as NSString).standardizingPath

        guard !visited.contains(canonical) else {
            logger.warning("SSH config circular Include: \(path, privacy: .public)")
            return []
        }

        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return []
        }

        visited.insert(canonical)
        sources.append(canonical)

        let baseDir = URL(fileURLWithPath: path).deletingLastPathComponent()
        return parseLines(
            content.components(separatedBy: .newlines),
            baseDir: baseDir,
            visited: &visited,
            sources: &sources,
            depth: depth
        )
    }

    private static func parseLines(
        _ lines: [String],
        baseDir: URL?,
        visited: inout Set<String>,
        sources: inout [String],
        depth: Int
    ) -> [SSHConfigBlock] {
        var blocks: [SSHConfigBlock] = []
        var pending = PendingBlock(criteria: .global)

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let (key, value) = splitKeyValue(trimmed)
            guard !key.isEmpty else { continue }

            switch key.lowercased() {
            case "host":
                pending.flush(into: &blocks)
                pending = PendingBlock(criteria: .host(patterns: SSHHostPatternMatcher.parsePatternList(value)))

            case "match":
                pending.flush(into: &blocks)
                let conditions = parseMatchConditions(value)
                pending = PendingBlock(criteria: .match(conditions: conditions))

            case "include":
                let resolved = resolveIncludePaths(value, baseDir: baseDir)
                for includePath in resolved {
                    let included = parseFile(
                        path: includePath,
                        visited: &visited,
                        sources: &sources,
                        depth: depth + 1
                    )
                    blocks.append(contentsOf: included)
                }

            default:
                if let directive = parseDirective(key: key, value: value) {
                    pending.directives.append(directive)
                }
            }
        }

        pending.flush(into: &blocks)
        return blocks
    }

    // MARK: - Directive parsing

    private static func splitKeyValue(_ line: String) -> (String, String) {
        guard let separatorRange = line.rangeOfCharacter(from: CharacterSet(charactersIn: " \t=")) else {
            return (line, "")
        }
        let key = String(line[line.startIndex..<separatorRange.lowerBound])
        var value = String(line[separatorRange.upperBound...])
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t="))
        if value.count >= 2, value.first == "\"", value.last == "\"" {
            value = String(value.dropFirst().dropLast())
        }
        return (key, value)
    }

    private static func parseDirective(key: String, value: String) -> SSHDirective? {
        switch key.lowercased() {
        case "hostname":
            return .hostName(value)
        case "port":
            return Int(value).map { .port($0) }
        case "user":
            return .user(value)
        case "identityfile":
            return .identityFile(value)
        case "identityagent":
            return .identityAgent(value)
        case "proxyjump":
            return .proxyJump(value)
        case "identitiesonly":
            return .identitiesOnly(parseBool(value))
        case "addkeystoagent":
            return .addKeysToAgent(parseBool(value))
        case "usekeychain":
            return .useKeychain(parseBool(value))
        case "canonicalizehostname":
            return .canonicalizeHostname(parseCanonicalizeMode(value))
        case "canonicaldomains":
            let domains = value.components(separatedBy: CharacterSet(charactersIn: ", \t"))
                .filter { !$0.isEmpty }
            return .canonicalDomains(domains)
        case "canonicalizepermittedcnames":
            return .canonicalizePermittedCNAMEs(value)
        case "canonicalizefallbacklocal":
            return .canonicalizeFallbackLocal(parseBool(value))
        case "canonicalizemaxdots":
            return Int(value).map { .canonicalizeMaxDots($0) }
        default:
            return .unrecognized(key: key, value: value)
        }
    }

    private static func parseBool(_ value: String) -> Bool {
        value.lowercased() == "yes"
    }

    private static func parseCanonicalizeMode(_ value: String) -> CanonicalizeMode {
        switch value.lowercased() {
        case "yes": return .yes
        case "always": return .always
        default: return .no
        }
    }

    private static func parseMatchConditions(_ value: String) -> [MatchCondition] {
        var tokens = tokenize(value)
        var conditions: [MatchCondition] = []

        while !tokens.isEmpty {
            let keyword = tokens.removeFirst().lowercased()
            switch keyword {
            case "all":
                conditions.append(.all)
            case "canonical":
                conditions.append(.canonical)
            case "final":
                conditions.append(.final)
            case "host":
                if let arg = tokens.first {
                    tokens.removeFirst()
                    conditions.append(.host(patterns: SSHHostPatternMatcher.parsePatternList(arg)))
                }
            case "originalhost":
                if let arg = tokens.first {
                    tokens.removeFirst()
                    conditions.append(.originalHost(patterns: SSHHostPatternMatcher.parsePatternList(arg)))
                }
            case "user":
                if let arg = tokens.first {
                    tokens.removeFirst()
                    conditions.append(.user(patterns: SSHHostPatternMatcher.parsePatternList(arg)))
                }
            case "localuser":
                if let arg = tokens.first {
                    tokens.removeFirst()
                    conditions.append(.localUser(patterns: SSHHostPatternMatcher.parsePatternList(arg)))
                }
            case "exec":
                if let arg = tokens.first {
                    tokens.removeFirst()
                    conditions.append(.exec(command: arg))
                }
            default:
                if !tokens.isEmpty { tokens.removeFirst() }
            }
        }
        return conditions
    }

    private static func tokenize(_ value: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false

        for char in value {
            if inQuotes {
                if char == "\"" {
                    inQuotes = false
                    tokens.append(current)
                    current = ""
                } else {
                    current.append(char)
                }
            } else if char == "\"" {
                inQuotes = true
            } else if char == " " || char == "\t" {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }

        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    // MARK: - Include resolution

    private static func resolveIncludePaths(_ value: String, baseDir: URL?) -> [String] {
        let expanded = SSHPathUtilities.expandTilde(value)
        let resolved: String
        if expanded.hasPrefix("/") {
            resolved = expanded
        } else if let baseDir {
            resolved = baseDir.appendingPathComponent(expanded).path(percentEncoded: false)
        } else {
            let sshDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".ssh").path(percentEncoded: false)
            resolved = (sshDir as NSString).appendingPathComponent(expanded)
        }
        return globPaths(resolved)
    }

    private static func globPaths(_ pattern: String) -> [String] {
        var gt = glob_t()
        defer { globfree(&gt) }

        guard glob(pattern, GLOB_TILDE | GLOB_BRACE, nil, &gt) == 0 else {
            return []
        }

        var paths: [String] = []
        for i in 0..<Int(gt.gl_matchc) {
            if let cStr = gt.gl_pathv[i] {
                paths.append(String(cString: cStr))
            }
        }
        return paths.sorted()
    }

    // MARK: - Pending block

    private struct PendingBlock {
        let criteria: SSHConfigCriteria
        var directives: [SSHDirective] = []

        mutating func flush(into blocks: inout [SSHConfigBlock]) {
            if case .global = criteria, directives.isEmpty { return }
            blocks.append(SSHConfigBlock(criteria: criteria, directives: directives))
        }
    }

    // MARK: - Picker flattening

    private static func flatten(_ document: SSHConfigDocument) -> [SSHConfigEntry] {
        var entries: [SSHConfigEntry] = []
        for block in document.blocks {
            guard case .host(let patterns) = block.criteria else { continue }
            guard patterns.count == 1, !patterns[0].negated else { continue }
            let glob = patterns[0].glob
            if glob.contains("*") || glob.contains("?") || glob.contains(" ") { continue }

            var hostname: String?
            var port: Int?
            var user: String?
            var identityFiles: [String] = []
            var identityAgent: String?
            var proxyJump: String?
            var identitiesOnly: Bool?
            var addKeysToAgent: Bool?
            var useKeychain: Bool?

            for directive in block.directives {
                switch directive {
                case .hostName(let value): hostname = value
                case .port(let value): port = value
                case .user(let value): user = value
                case .identityFile(let value): identityFiles.append(value)
                case .identityAgent(let value): identityAgent = value
                case .proxyJump(let value): proxyJump = value
                case .identitiesOnly(let value): identitiesOnly = value
                case .addKeysToAgent(let value): addKeysToAgent = value
                case .useKeychain(let value): useKeychain = value
                default: break
                }
            }

            entries.append(
                SSHConfigEntry(
                    host: glob,
                    hostname: hostname,
                    port: port,
                    user: user,
                    identityFiles: identityFiles.map {
                        SSHPathUtilities.expandSSHTokens(
                            $0,
                            hostname: hostname,
                            originalHost: glob,
                            port: port,
                            remoteUser: user
                        )
                    },
                    identityAgent: identityAgent.map {
                        SSHPathUtilities.expandSSHTokens(
                            $0,
                            hostname: hostname,
                            originalHost: glob,
                            port: port,
                            remoteUser: user
                        )
                    },
                    proxyJump: proxyJump,
                    identitiesOnly: identitiesOnly,
                    addKeysToAgent: addKeysToAgent,
                    useKeychain: useKeychain
                )
            )
        }
        return entries
    }
}
