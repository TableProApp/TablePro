//
//  ResolvedSSHTarget.swift
//  TablePro
//

import Foundation

struct ResolvedSSHTarget: Sendable, Hashable {
    let originalHost: String
    let host: String
    let port: Int
    let username: String
    let identityFiles: [String]
    let agentSocketPath: String
    let identitiesOnly: Bool
    let useKeychain: Bool
    let addKeysToAgent: Bool
    let proxyJump: [SSHJumpHost]
}
