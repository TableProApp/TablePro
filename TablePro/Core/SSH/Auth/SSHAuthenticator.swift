//
//  SSHAuthenticator.swift
//  TablePro
//

import Foundation

import CLibSSH2

/// Protocol for SSH authentication methods
internal protocol SSHAuthenticator: Sendable {
    /// Authenticate the SSH session
    /// - Parameters:
    ///   - session: libssh2 session pointer
    ///   - username: SSH username
    /// - Throws: SSHTunnelError on failure
    func authenticate(session: OpaquePointer, username: String) throws
}
