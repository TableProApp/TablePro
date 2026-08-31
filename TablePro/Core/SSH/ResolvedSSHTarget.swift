//
//  ResolvedSSHTarget.swift
//  TablePro
//

import Foundation

/// Where the agent socket a connection will use came from. `agentSocketPath` collapses three
/// sources into one string, and each is changed somewhere different, so an agent that does not
/// answer can only be reported usefully alongside the source that named it.
enum AgentSocketOrigin: Sendable, Hashable, CaseIterable {
    /// The Agent Socket control on the SSH Tunnel pane.
    case agentSocketSetting
    /// An `IdentityAgent` directive matching this host in `~/.ssh/config`.
    case identityAgentDirective
    /// `SSH_AUTH_SOCK`, from the process environment or launchd.
    case environment
}

struct ResolvedSSHTarget: Sendable, Hashable {
    let originalHost: String
    let host: String
    let port: Int
    let username: String
    let identityFiles: [String]
    let agentSocketPath: String
    let agentSocketOrigin: AgentSocketOrigin
    let identitiesOnly: Bool
    let useKeychain: Bool
    let addKeysToAgent: Bool
    let proxyJump: [SSHJumpHost]
}
