//
//  PublicKeyAuthenticator.swift
//  TablePro
//

import Foundation

import CLibSSH2

internal struct PublicKeyAuthenticator: SSHAuthenticator {
    let privateKeyPath: String
    let passphrase: String?
    /// When true and passphrase is nil, prompts user interactively for the passphrase.
    let promptIfNeeded: Bool

    init(privateKeyPath: String, passphrase: String?, promptIfNeeded: Bool = false) {
        self.privateKeyPath = privateKeyPath
        self.passphrase = passphrase
        self.promptIfNeeded = promptIfNeeded
    }

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

        // Try with the provided passphrase first
        let effectivePassphrase = passphrase?.isEmpty == false ? passphrase : nil
        var rc = tryAuth(session: session, username: username, path: expandedPath, passphrase: effectivePassphrase)

        // If auth failed and we can prompt, ask the user for the passphrase
        if rc != 0 && promptIfNeeded && effectivePassphrase == nil {
            let provider = PromptPassphraseProvider(keyPath: expandedPath)
            if let prompted = provider.providePassphrase(), !prompted.isEmpty {
                rc = tryAuth(session: session, username: username, path: expandedPath, passphrase: prompted)
            }
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

    private func tryAuth(session: OpaquePointer, username: String, path: String, passphrase: String?) -> Int32 {
        let pubKeyPath = path + ".pub"
        let hasPubKey = FileManager.default.fileExists(atPath: pubKeyPath)

        if hasPubKey {
            return pubKeyPath.withCString { pubKeyCStr in
                libssh2_userauth_publickey_fromfile_ex(
                    session,
                    username, UInt32(username.utf8.count),
                    pubKeyCStr,
                    path,
                    passphrase
                )
            }
        } else {
            return libssh2_userauth_publickey_fromfile_ex(
                session,
                username, UInt32(username.utf8.count),
                nil,
                path,
                passphrase
            )
        }
    }
}
