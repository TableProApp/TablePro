//
//  SSHUnsupportedDirective.swift
//  TablePro
//

import Foundation

/// Classifies the `~/.ssh/config` directives TablePro does not parse. Most of them are cosmetic
/// or already match the default, so reporting all of them would bury the few that matter. These
/// decide how the connection reaches the server, and ignoring one sends TablePro somewhere the
/// command line would never have gone. `ProxyCommand` is the case that bites: OpenSSH reaches
/// the server by running the command, TablePro dials the hostname directly, and the difference
/// shows up only as a connection that fails with nothing pointing at the config.
internal enum SSHUnsupportedDirective {
    private static let routingKeys: Set<String> = [
        "proxycommand",
        "proxyusefdpass",
    ]

    static func changesRouting(key: String) -> Bool {
        routingKeys.contains(key.lowercased())
    }
}
