//
//  SSHConfigParser.swift
//  TablePro
//
//  Parser for ~/.ssh/config file to auto-fill SSH connection details
//

import Foundation

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
    /// Default SSH config file path
    static let defaultConfigPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".ssh/config").path(percentEncoded: false)

    /// Parse SSH config file and return all entries
    /// - Parameter path: Path to the SSH config file (defaults to ~/.ssh/config)
    /// - Returns: Array of SSHConfigEntry
    static func parse(path: String = defaultConfigPath) -> [SSHConfigEntry] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return []
        }

        return parseContent(content)
    }

    /// Parse SSH config content string
    /// - Parameter content: The content of the SSH config file
    /// - Returns: Array of SSHConfigEntry
    static func parseContent(_ content: String) -> [SSHConfigEntry] {
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
                    // Skip wildcard patterns like "*"
                    if !host.contains("*") && !host.contains("?") {
                        entries.append(
                            SSHConfigEntry(
                                host: host,
                                hostname: currentHostname,
                                port: currentPort,
                                user: currentUser,
                                identityFile: currentIdentityFile.map(SSHPathUtilities.expandTilde),
                                identityAgent: currentIdentityAgent.map(SSHPathUtilities.expandTilde),
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

            default:
                break  // Ignore other directives
            }
        }

        // Don't forget the last entry
        if let host = currentHost, !host.contains("*"), !host.contains("?") {
            entries.append(
                SSHConfigEntry(
                    host: host,
                    hostname: currentHostname,
                    port: currentPort,
                    user: currentUser,
                    identityFile: currentIdentityFile.map(SSHPathUtilities.expandTilde),
                    identityAgent: currentIdentityAgent.map(SSHPathUtilities.expandTilde),
                    proxyJump: currentProxyJump
                ))
        }

        return entries
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
