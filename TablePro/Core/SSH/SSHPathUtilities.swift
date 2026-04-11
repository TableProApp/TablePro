//
//  SSHPathUtilities.swift
//  TablePro
//

import Foundation

enum SSHPathUtilities {
    /// Expand ~ to the current user's home directory in a path.
    /// Unlike shell commands, `setenv()` and file APIs do not expand `~` automatically.
    static func expandTilde(_ path: String) -> String {
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2)))
                .path(percentEncoded: false)
        }
        if path == "~" {
            return FileManager.default.homeDirectoryForCurrentUser
                .path(percentEncoded: false)
        }
        return path
    }

    /// Expand SSH config tokens and tilde in a path.
    /// Supports: %d (user home directory), %h (hostname), %u (local username),
    /// %r (remote username), %% (literal %). See ssh_config(5) TOKENS section.
    static func expandSSHTokens(
        _ path: String,
        hostname: String? = nil,
        remoteUser: String? = nil
    ) -> String {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
            .path(percentEncoded: false)
        let localUser = NSUserName()

        // Protect literal %% from token expansion
        let sentinel = "\u{FFFF}"
        var result = path.replacingOccurrences(of: "%%", with: sentinel)

        result = result.replacingOccurrences(of: "%d", with: homeDir)
        if let hostname {
            result = result.replacingOccurrences(of: "%h", with: hostname)
        }
        result = result.replacingOccurrences(of: "%u", with: localUser)
        if let remoteUser {
            result = result.replacingOccurrences(of: "%r", with: remoteUser)
        }

        result = result.replacingOccurrences(of: sentinel, with: "%")

        return expandTilde(result)
    }
}
