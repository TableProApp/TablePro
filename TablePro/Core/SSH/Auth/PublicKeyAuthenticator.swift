//
//  PublicKeyAuthenticator.swift
//  TablePro
//

import Foundation

import CLibSSH2

internal struct PublicKeyAuthenticator: SSHAuthenticator {
    let privateKeyPath: String
    let passphrase: String?

    func authenticate(session: OpaquePointer, username: String) throws {
        let expandedPath = SSHPathUtilities.expandTilde(privateKeyPath)

        guard FileManager.default.fileExists(atPath: expandedPath) else {
            throw SSHTunnelError.tunnelCreationFailed(
                "Private key file not found at: \(expandedPath)"
            )
        }
        guard FileManager.default.isReadableFile(atPath: expandedPath) else {
            throw SSHTunnelError.tunnelCreationFailed(
                "Private key file not readable. Check permissions (should be 600): \(expandedPath)"
            )
        }

        let pubKeyPath = expandedPath + ".pub"
        let hasPubKey = FileManager.default.fileExists(atPath: pubKeyPath)

        let rc: Int32
        if hasPubKey {
            rc = pubKeyPath.withCString { pubKeyCStr in
                libssh2_userauth_publickey_fromfile_ex(
                    session,
                    username, UInt32(username.utf8.count),
                    pubKeyCStr,
                    expandedPath,
                    passphrase
                )
            }
        } else {
            rc = libssh2_userauth_publickey_fromfile_ex(
                session,
                username, UInt32(username.utf8.count),
                nil,
                expandedPath,
                passphrase
            )
        }

        guard rc == 0 else {
            var msgPtr: UnsafeMutablePointer<CChar>?
            var msgLen: Int32 = 0
            libssh2_session_last_error(session, &msgPtr, &msgLen, 0)
            let detail = msgPtr.map { String(cString: $0) } ?? "Unknown error"
            throw SSHTunnelError.tunnelCreationFailed(
                "Public key authentication failed: \(detail)"
            )
        }
    }
}
