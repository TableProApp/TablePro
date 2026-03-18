//
//  CompositeAuthenticator.swift
//  TablePro
//

import Foundation
import os

import CLibSSH2

/// Authenticator that tries multiple auth methods in sequence.
/// Used for servers requiring e.g. password + keyboard-interactive (TOTP).
internal struct CompositeAuthenticator: SSHAuthenticator {
    private static let logger = Logger(subsystem: "com.TablePro", category: "CompositeAuthenticator")

    let authenticators: [any SSHAuthenticator]

    func authenticate(session: OpaquePointer, username: String) throws {
        var lastError: Error?
        for (index, authenticator) in authenticators.enumerated() {
            Self.logger.debug("Trying authenticator \(index + 1)/\(authenticators.count)")
            do {
                try authenticator.authenticate(session: session, username: username)
            } catch {
                Self.logger.debug("Authenticator \(index + 1) failed: \(error)")
                lastError = error
            }

            if libssh2_userauth_authenticated(session) != 0 {
                Self.logger.info("Authentication succeeded after \(index + 1) step(s)")
                return
            }
        }

        if libssh2_userauth_authenticated(session) == 0 {
            throw lastError ?? SSHTunnelError.authenticationFailed
        }
    }
}
