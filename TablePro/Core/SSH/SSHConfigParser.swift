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

    /// Splits a `ProxyJump` value into its hops. Kept separate from parsing because the hops have
    /// to be split before their tokens are expanded, which is the order ssh uses: expanding first
    /// lets a value carrying a comma, `%r` with a username like `bob,evil.example.net`, turn one
    /// configured hop into two and route the session through a host the config never named.
    static func splitProxyJumpHops(_ value: String) -> [String] {
        value
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func parseProxyJump(_ value: String) -> [SSHJumpHost] {
        splitProxyJumpHops(value).compactMap(parseProxyJumpHop)
    }

    static func parseProxyJumpHop(_ hop: String) -> SSHJumpHost? {
        guard !hop.isEmpty else { return nil }

        var jumpHost = SSHJumpHost()
        var remaining = hop

        // The LAST `@` separates the user: `%r` expands to the remote username, and a
        // UPN-style one carries its own `@`, which splitting on the first left inside the host.
        if let atIndex = remaining.lastIndex(of: "@") {
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
                  !remaining[remaining.startIndex..<colonIndex].contains(":"),
                  let port = Int(String(remaining[remaining.index(after: colonIndex)...])) {
            // An unbracketed address with more than one colon is an IPv6 literal, which ssh
            // accepts from an expanded `%h`. Reading its last group as a port left `::` as
            // the host and `1` as the port.
            jumpHost.host = String(remaining[remaining.startIndex..<colonIndex])
            jumpHost.port = port
        } else {
            jumpHost.host = remaining
        }

        return jumpHost
    }

    // MARK: - File parsing

    private static func parseFile(
        path: String,
        visited: inout Set<String>,
        sources: inout [String],
        depth: Int
    ) -> [SSHConfigBlock] {
        var pending = PendingBlock(criteria: .global)
        var blocks: [SSHConfigBlock] = []
        appendFile(
            path: path,
            into: &blocks,
            pending: &pending,
            visited: &visited,
            sources: &sources,
            depth: depth
        )
        pending.flush(into: &blocks)
        return blocks
    }

    /// Reads one file and folds its directives into the block list, carrying `pending` across the
    /// call so an `Include` behaves the way ssh does: as if the included lines were written where
    /// the `Include` stands, inside whatever `Host` or `Match` block encloses it.
    ///
    /// `visited` is an ancestor stack, not a set of every file ever read. A file is only a cycle
    /// while it is still being read, and the same snippet legitimately gets included from several
    /// blocks: keeping it in the set after the read returned made every occurrence after the first
    /// contribute nothing.
    private static func appendFile(
        path: String,
        into blocks: inout [SSHConfigBlock],
        pending: inout PendingBlock,
        visited: inout Set<String>,
        sources: inout [String],
        depth: Int
    ) {
        guard depth <= maxIncludeDepth else {
            logger.warning("SSH config Include depth exceeded at: \(path, privacy: .public)")
            return
        }

        let canonical = (path as NSString).standardizingPath

        guard !visited.contains(canonical) else {
            logger.warning("SSH config circular Include: \(path, privacy: .public)")
            return
        }

        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return
        }

        visited.insert(canonical)
        defer { visited.remove(canonical) }
        if !sources.contains(canonical) {
            sources.append(canonical)
        }

        appendLines(
            content.components(separatedBy: .newlines),
            baseDir: URL(fileURLWithPath: path).deletingLastPathComponent(),
            into: &blocks,
            pending: &pending,
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
        appendLines(
            lines,
            baseDir: baseDir,
            into: &blocks,
            pending: &pending,
            visited: &visited,
            sources: &sources,
            depth: depth
        )
        pending.flush(into: &blocks)
        return blocks
    }

    private static func appendLines(
        _ lines: [String],
        baseDir: URL?,
        into blocks: inout [SSHConfigBlock],
        pending: inout PendingBlock,
        visited: inout Set<String>,
        sources: inout [String],
        depth: Int
    ) {
        for rawLine in lines {
            let trimmed = stripComment(from: rawLine).trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            let (key, value) = splitKeyValue(trimmed)
            guard !key.isEmpty else { continue }

            switch key.lowercased() {
            case "host":
                pending.flush(into: &blocks)
                pending = PendingBlock(criteria: .host(patterns: SSHHostPatternMatcher.parseHostPatternList(value)))

            case "match":
                pending.flush(into: &blocks)
                pending = PendingBlock(criteria: .match(conditions: parseMatchConditions(value)))

            case "include":
                for includePath in resolveIncludePaths(value, baseDir: baseDir) {
                    appendFile(
                        path: includePath,
                        into: &blocks,
                        pending: &pending,
                        visited: &visited,
                        sources: &sources,
                        depth: depth + 1
                    )
                }

            default:
                if let directive = parseDirective(key: key, value: value) {
                    pending.directives.append(directive)
                }
            }
        }
    }

    /// Drops a trailing comment. A `#` only opens one where it starts a whitespace-delimited
    /// argument and stands outside quotes, measured: `HostName db.example.com#one` keeps its `#`,
    /// `HostName db.example.com #one` does not, and `HostName "db#1.example.com"` keeps it too.
    /// Cutting at the first `#` instead sent `db.example.com   # production` to `getaddrinfo`.
    private static func stripComment(from line: String) -> String {
        var inQuotes = false
        var previousWasSeparator = true

        for index in line.indices {
            let character = line[index]
            if character == "\"" {
                inQuotes.toggle()
                previousWasSeparator = false
                continue
            }
            if character == "#", !inQuotes, previousWasSeparator {
                return String(line[line.startIndex..<index])
            }
            previousWasSeparator = character == " " || character == "\t"
        }
        return line
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
        case "hostkeyalias":
            return .hostKeyAlias(value)
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

    /// Any criterion may be negated with a leading `!`, per ssh_config(5). Dropping the negation
    /// turned `Match !host prod-db` into a block with no conditions at all, which then matched
    /// every host including the one it was written to exclude.
    private static func parseMatchConditions(_ value: String) -> [MatchCondition] {
        var tokens = tokenize(value)
        var conditions: [MatchCondition] = []

        while !tokens.isEmpty {
            var keyword = tokens.removeFirst().lowercased()
            var negated = false
            if keyword.hasPrefix("!") {
                negated = true
                keyword = String(keyword.dropFirst())
            }

            let test: MatchTest?
            switch keyword {
            case "all":
                test = .all
            case "canonical":
                test = .canonical
            case "final":
                test = .final
            case "host":
                test = takeArgument(&tokens).map { .host(patterns: matchPatterns($0)) }
            case "originalhost":
                test = takeArgument(&tokens).map { .originalHost(patterns: matchPatterns($0)) }
            case "user":
                test = takeArgument(&tokens).map { .user(patterns: matchPatterns($0)) }
            case "localuser":
                test = takeArgument(&tokens).map { .localUser(patterns: matchPatterns($0)) }
            case "exec":
                test = takeArgument(&tokens).map { .exec(command: $0) }
            default:
                if !tokens.isEmpty { tokens.removeFirst() }
                test = nil
            }

            if let test {
                conditions.append(MatchCondition(test: test, negated: negated))
            }
        }
        return conditions
    }

    private static func takeArgument(_ tokens: inout [String]) -> String? {
        guard !tokens.isEmpty else { return nil }
        return tokens.removeFirst()
    }

    private static func matchPatterns(_ argument: String) -> [HostPattern] {
        SSHHostPatternMatcher.parseMatchPatternList(argument)
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

    /// `Include` takes several whitespace-separated paths, and each is globbed on its own. Passing
    /// the whole line to `glob(3)` as one pattern made it return `GLOB_NOMATCH`, so a line naming
    /// two files silently contributed neither.
    ///
    /// Only the host-independent tokens are expanded. The parsed document is cached once and shared
    /// by every connection, so no host is known at this point; `%h` and its neighbours are left
    /// alone rather than resolved against the wrong target.
    private static func resolveIncludePaths(_ value: String, baseDir: URL?) -> [String] {
        tokenize(value).flatMap { resolveIncludePath($0, baseDir: baseDir) }
    }

    private static func resolveIncludePath(_ path: String, baseDir: URL?) -> [String] {
        let substituted: String
        do {
            substituted = try SSHTokenContext().expand(path, scope: .includePath, keyword: "Include")
        } catch {
            logger.warning(
                "Skipping Include \(path, privacy: .public): TablePro reads ~/.ssh/config once for every connection, so a token that names the target cannot be resolved here"
            )
            return []
        }
        let expanded = SSHPathUtilities.expandTilde(substituted)

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
                            keyword: "IdentityFile",
                            hostname: hostname ?? glob,
                            originalHost: glob,
                            port: port,
                            remoteUser: user,
                            jumpHost: proxyJump
                        )
                    },
                    identityAgent: identityAgent.map {
                        SSHPathUtilities.expandSSHTokens(
                            $0,
                            keyword: "IdentityAgent",
                            hostname: hostname ?? glob,
                            originalHost: glob,
                            port: port,
                            remoteUser: user,
                            jumpHost: proxyJump
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
