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
}
