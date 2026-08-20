//
//  NoneAuthenticator.swift
//  TablePro
//

import Foundation
import os

import CLibSSH2

internal struct NoneAuthenticator: SSHAuthenticator {
    private static let logger = Logger(subsystem: "com.TablePro", category: "NoneAuthenticator")

    func authenticate(session: OpaquePointer, username: String) throws {
        let authList = libssh2_userauth_list(session, username, UInt32(username.utf8.count))
        guard authList == nil else {
            Self.logger.error("Passwordless auth rejected; server requires credentials")
            throw SSHTunnelError.authenticationFailed(reason: .passwordlessRejected)
        }

        guard libssh2_userauth_authenticated(session) != 0 else {
            var msgPtr: UnsafeMutablePointer<CChar>?
            var msgLen: Int32 = 0
            libssh2_session_last_error(session, &msgPtr, &msgLen, 0)
            let detail = msgPtr.map { String(cString: $0) } ?? "Unknown error"
            Self.logger.error("Passwordless auth failed: \(detail)")
            throw SSHTunnelError.authenticationFailed(reason: .passwordlessRejected)
        }

        Self.logger.info("Passwordless authentication succeeded")
    }
}
