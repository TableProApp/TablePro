//
//  SSHPathUtilities.swift
//  TablePro
//

import Foundation

enum SSHPathUtilities {
    /// Expand a leading `~` or `~user` the way ssh does for the keywords that name a file.
    /// `setenv()` and the file APIs do not do this for you, unlike a shell.
    static func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        return (path as NSString).expandingTildeInPath
    }

    /// Expand the tokens a file-naming keyword accepts, then the tilde. Used where the caller has
    /// no resolver context, which is the connection form's `~/.ssh/config` picker.
    static func expandSSHTokens(
        _ path: String,
        keyword: String,
        hostname: String? = nil,
        originalHost: String? = nil,
        port: Int? = nil,
        remoteUser: String? = nil,
        jumpHost: String? = nil
    ) -> String {
        let context = SSHTokenContext(
            originalHost: originalHost,
            hostname: hostname,
            port: port,
            remoteUser: remoteUser,
            jumpHost: jumpHost
        )
        guard let expanded = try? context.expand(path, scope: .standard, keyword: keyword) else {
            return path
        }
        return expandTilde(expanded)
    }
}
