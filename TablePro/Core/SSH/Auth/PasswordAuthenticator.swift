//
//  PasswordAuthenticator.swift
//  TablePro
//

import Foundation

import CLibSSH2

internal struct PasswordAuthenticator: SSHAuthenticator {
    let password: String

    func authenticate(session: OpaquePointer, username: String) throws {
        let rc = libssh2_userauth_password_ex(
            session,
            username, UInt32(username.utf8.count),
            password, UInt32(password.utf8.count),
            nil
        )
        guard rc == 0 else {
            throw SSHTunnelError.authenticationFailed
        }
    }
}
