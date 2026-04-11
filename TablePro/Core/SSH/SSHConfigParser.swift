//
//  SSHConfigParser.swift
//  TablePro
//
//  Parser for ~/.ssh/config file to auto-fill SSH connection details
//

import Foundation
import os

/// Represents a parsed entry from ~/.ssh/config
struct SSHConfigEntry: Identifiable, Hashable {
    let id = UUID()
    let host: String  // Host pattern (alias used in ssh command)
    let hostname: String?  // Actual hostname/IP
    let port: Int?  // Port number
    let user: String?  // Username
    let identityFile: String?  // Path to private key
    let identityAgent: String?  // Path to SSH agent socket
    let proxyJump: String?  // ProxyJump directive

    /// Display name for UI
    var displayName: String {
        if let hostname = hostname, hostname != host {
            return "\(host) (\(hostname))"
        }
        return host
    }
}

/// Parser for SSH config file (~/.ssh/config)
final class SSHConfigParser {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SSHConfigParser")
    private static let maxIncludeDepth = 10

    /// Default SSH config file path
    static let defaultConfigPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".ssh/config").path(percentEncoded: false)

    /// Parse SSH config file and return all entries
    /// - Parameter path: Path to the SSH config file (defaults to ~/.ssh/config)
    /// - Returns: Array of SSHConfigEntry
    static func parse(path: String = defaultConfigPath) -> [SSHConfigEntry] {
        var visitedPaths = Set<String>()
        return parseFile(path: path, visitedPaths: &visitedPaths, depth: 0)
    }

    /// Parse SSH config content string
    /// - Parameter content: The content of the SSH config file
    /// - Returns: Array of SSHConfigEntry
    static func parseContent(_ content: String) -> [SSHConfigEntry] {
        var visited = Set<String>()
        return parseContent(content, visitedPaths: &visited, depth: 0)
    }

    /// Parse SSH config file with Include support.
    private static func parseFile(
        path: String,
        visitedPaths: inout Set<String>,
        depth: Int
    ) -> [SSHConfigEntry] {
        guard depth <= maxIncludeDepth else {
            logger.warning("SSH config Include depth exceeded at: \(path)")
            return []
        }

        let canonicalPath = (path as NSString).standardizingPath

        guard !visitedPaths.contains(canonicalPath) else {
            logger.warning("SSH config circular Include detected: \(path)")
            return []
        }

        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return []
        }

        visitedPaths.insert(canonicalPath)

        return parseContent(content, visitedPaths: &visitedPaths, depth: depth)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private static func parseContent(
        _ content: String,
        visitedPaths: inout Set<String>,
        depth: Int
    ) -> [SSHConfigEntry] {
        var entries: [SSHConfigEntry] = []
        var currentHost: String?
        var currentHostname: String?
        var currentPort: Int?
        var currentUser: String?
        var currentIdentityFile: String?
        var currentIdentityAgent: String?
        var currentProxyJump: String?

        let lines = content.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            // Parse key-value pair
            let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 2 else { continue }

            let key = parts[0].lowercased()
            let value = parts.dropFirst().joined(separator: " ")

            switch key {
            case "host":
                // Save previous entry if exists
                if let host = currentHost {
                    // Skip wildcard patterns and multi-word hosts
                    if !host.contains("*") && !host.contains("?") && !host.contains(" ") {
                        entries.append(
                            SSHConfigEntry(
                                host: host,
                                hostname: currentHostname,
                                port: currentPort,
                                user: currentUser,
                                identityFile: currentIdentityFile.map {
                                    SSHPathUtilities.expandSSHTokens(
                                        $0, hostname: currentHostname, remoteUser: currentUser)
                                },
                                identityAgent: currentIdentityAgent.map {
                                    SSHPathUtilities.expandSSHTokens(
                                        $0, hostname: currentHostname, remoteUser: currentUser)
                                },
                                proxyJump: currentProxyJump
                            ))
                    }
                }

                // Start new entry
                currentHost = value
                currentHostname = nil
                currentPort = nil
                currentUser = nil
                currentIdentityFile = nil
                currentIdentityAgent = nil
                currentProxyJump = nil

            case "hostname":
                currentHostname = value

            case "port":
                currentPort = Int(value)

            case "user":
                currentUser = value

            case "identityfile":
                currentIdentityFile = value

            case "identityagent":
                currentIdentityAgent = value

            case "proxyjump":
                currentProxyJump = value

            case "include":
                // Flush current pending entry before processing includes
                if let host = currentHost {
                    if !host.contains("*") && !host.contains("?") && !host.contains(" ") {
                        entries.append(
                            SSHConfigEntry(
                                host: host,
                                hostname: currentHostname,
                                port: currentPort,
                                user: currentUser,
                                identityFile: currentIdentityFile.map {
                                    SSHPathUtilities.expandSSHTokens(
                                        $0, hostname: currentHostname, remoteUser: currentUser)
                                },
                                identityAgent: currentIdentityAgent.map {
                                    SSHPathUtilities.expandSSHTokens(
                                        $0, hostname: currentHostname, remoteUser: currentUser)
                                },
                                proxyJump: currentProxyJump
                            ))
                    }
                    currentHost = nil
                    currentHostname = nil
                    currentPort = nil
                    currentUser = nil
                    currentIdentityFile = nil
                    currentIdentityAgent = nil
                    currentProxyJump = nil
                }

                let includePaths = resolveIncludePaths(value)
                for includePath in includePaths {
                    let includedEntries = parseFile(
                        path: includePath,
                        visitedPaths: &visitedPaths,
                        depth: depth + 1
                    )
                    entries.append(contentsOf: includedEntries)
                }

            default:
                break  // Ignore other directives
            }
        }

        // Don't forget the last entry
        if let host = currentHost, !host.contains("*"), !host.contains("?"), !host.contains(" ") {
            entries.append(
                SSHConfigEntry(
                    host: host,
                    hostname: currentHostname,
                    port: currentPort,
                    user: currentUser,
                    identityFile: currentIdentityFile.map {
                        SSHPathUtilities.expandSSHTokens(
                            $0, hostname: currentHostname, remoteUser: currentUser)
                    },
                    identityAgent: currentIdentityAgent.map {
                        SSHPathUtilities.expandSSHTokens(
                            $0, hostname: currentHostname, remoteUser: currentUser)
                    },
                    proxyJump: currentProxyJump
                ))
        }

        return entries
    }

    /// Expand a glob pattern to matching file paths using POSIX glob(3).
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

    /// Resolve an Include directive value to actual file paths.
    /// Relative paths are resolved against ~/.ssh/ per OpenSSH convention.
    private static func resolveIncludePaths(_ value: String) -> [String] {
        let expanded = SSHPathUtilities.expandTilde(value)

        // Relative paths resolve against ~/.ssh/ per OpenSSH convention
        let resolved: String
        if expanded.hasPrefix("/") {
            resolved = expanded
        } else {
            let sshDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".ssh").path(percentEncoded: false)
            resolved = (sshDir as NSString).appendingPathComponent(expanded)
        }

        return globPaths(resolved)
    }

    /// Find a specific entry by host name
    /// - Parameters:
    ///   - host: The host name to search for
    ///   - path: Path to the SSH config file
    /// - Returns: The matching SSHConfigEntry or nil
    static func findEntry(for host: String, path: String = defaultConfigPath) -> SSHConfigEntry? {
        let entries = parse(path: path)
        return entries.first { $0.host.lowercased() == host.lowercased() }
    }

    /// Parse a ProxyJump value (e.g., "user@host:port,user2@host2") into SSHJumpHost array
    static func parseProxyJump(_ value: String) -> [SSHJumpHost] {
        let hops = value.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var jumpHosts: [SSHJumpHost] = []

        for hop in hops where !hop.isEmpty {
            var jumpHost = SSHJumpHost()

            var remaining = hop

            // Extract user@ prefix
            if let atIndex = remaining.firstIndex(of: "@") {
                jumpHost.username = String(remaining[remaining.startIndex..<atIndex])
                remaining = String(remaining[remaining.index(after: atIndex)...])
            }

            // Extract host and port (supports bracketed IPv6, e.g. [::1]:22)
            if remaining.hasPrefix("["),
               let closeBracket = remaining.firstIndex(of: "]") {
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
}
