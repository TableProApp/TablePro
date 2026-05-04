//
//  SSHPathUtilities.swift
//  TablePro
//

import CryptoKit
import Darwin
import Foundation

enum SSHPathUtilities {
    /// Expand ~ to the current user's home directory in a path.
    /// Unlike shell commands, `setenv()` and file APIs do not expand `~` automatically.
    static func expandTilde(_ path: String) -> String {
        if path.hasPrefix("~/") {
            return SSHTokenContext.localHomeDir + "/" + String(path.dropFirst(2))
        }
        if path == "~" {
            return SSHTokenContext.localHomeDir
        }
        return path
    }

    static func expandSSHTokens(
        _ path: String,
        hostname: String? = nil,
        originalHost: String? = nil,
        port: Int? = nil,
        remoteUser: String? = nil
    ) -> String {
        let context = SSHTokenContext(
            originalHost: originalHost,
            hostname: hostname,
            port: port,
            remoteUser: remoteUser
        )
        return expandTilde(context.expand(path))
    }
}

/// Snapshot of the values used to expand `%X` tokens.
/// Per ssh_config(5):
///   %d  Local user's home directory.
///   %h  The remote hostname (post-substitution).
///   %n  The original target hostname given on the command line.
///   %p  The remote port.
///   %r  The remote username.
///   %u  The local username.
///   %i  Local user ID.
///   %l  Local hostname (FQDN).
///   %L  Local hostname without the domain.
///   %T  Local TUN/TAP interface name. Always `NONE` for client connections.
///   %C  Hash of `%l%h%p%r`. Used by ControlPath etc.
///   %%  Literal %.
struct SSHTokenContext: Sendable {
    let originalHost: String?
    let hostname: String?
    let port: Int?
    let remoteUser: String?

    func expand(_ input: String) -> String {
        let sentinel = "\u{FFFF}"
        var result = input.replacingOccurrences(of: "%%", with: sentinel)

        result = result.replacingOccurrences(of: "%d", with: SSHTokenContext.localHomeDir)

        if let hostname {
            result = result.replacingOccurrences(of: "%h", with: hostname)
        }
        if let originalHost {
            result = result.replacingOccurrences(of: "%n", with: originalHost)
        }
        if let port {
            result = result.replacingOccurrences(of: "%p", with: String(port))
        }
        if let remoteUser {
            result = result.replacingOccurrences(of: "%r", with: remoteUser)
        }

        result = result.replacingOccurrences(of: "%u", with: NSUserName())
        result = result.replacingOccurrences(of: "%i", with: String(getuid()))
        result = result.replacingOccurrences(of: "%l", with: localHostnameFQDN())
        result = result.replacingOccurrences(of: "%L", with: localHostnameShort())
        result = result.replacingOccurrences(of: "%T", with: "NONE")

        if result.contains("%C") {
            let basis = "\(localHostnameFQDN())\(hostname ?? "")\(port.map(String.init) ?? "")\(remoteUser ?? "")"
            let digest = Insecure.SHA1.hash(data: Data(basis.utf8))
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            result = result.replacingOccurrences(of: "%C", with: hex)
        }

        return result.replacingOccurrences(of: sentinel, with: "%")
    }

    /// Trailing slash stripped because `URL.path(percentEncoded:)` preserves
    /// it for directory URLs, which produces double slashes on concatenation.
    static var localHomeDir: String {
        let raw = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    private func localHostnameFQDN() -> String {
        ProcessInfo.processInfo.hostName
    }

    private func localHostnameShort() -> String {
        let fqdn = localHostnameFQDN()
        if let dot = fqdn.firstIndex(of: ".") {
            return String(fqdn[..<dot])
        }
        return fqdn
    }
}
