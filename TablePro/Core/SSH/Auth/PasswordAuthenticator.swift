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
            var msgPtr: UnsafeMutablePointer<CChar>?
            var msgLen: Int32 = 0
            libssh2_session_last_error(session, &msgPtr, &msgLen, 0)
            let detail = msgPtr.map { String(cString: $0) } ?? "Unknown error"
            throw SSHTunnelError.tunnelCreationFailed(
                "Password authentication failed: \(detail)"
            )
        }
    }
}
