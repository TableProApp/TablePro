//
//  CompositeAuthenticator.swift
//  TablePro
//

import Foundation
import os

import CLibSSH2

/// Authenticator that tries multiple auth methods in sequence.
/// Used for servers requiring e.g. password + keyboard-interactive (TOTP).
///
/// The reported failure is the last step that actually offered the server a credential. A later
/// step the server never engaged (keyboard-interactive on a server that issues no prompt) would
/// otherwise bury the real reason: an SSH agent that never answered used to surface as
/// "SSH password rejected" on a connection that has no password.
internal struct CompositeAuthenticator: SSHAuthenticator {
    private static let logger = Logger(subsystem: "com.TablePro", category: "CompositeAuthenticator")

    let authenticators: [any SSHAuthenticator]

    /// Failures after which the remaining steps are not worth running. The SSH Agent chain names
    /// the two agent failures that mean no first factor was ever supplied, because the
    /// keyboard-interactive step behind them is a second factor and would otherwise ask for a
    /// credential of its own instead of reporting the agent.
    var endsChainOn: Set<AuthFailureReason> = []

    func authenticate(session: OpaquePointer, username: String) throws {
        var lastError: Error?
        for (index, authenticator) in authenticators.enumerated() {
            Self.logger.debug("Trying authenticator \(index + 1)/\(authenticators.count)")
            do {
                try authenticator.authenticate(session: session, username: username)
            } catch let error as SSHTunnelError where error.isUserCancelledAuthentication {
                throw error
            } catch {
                Self.logger.debug("Authenticator \(index + 1) failed: \(error)")
                if lastError == nil || Self.describesAnAttempt(error) {
                    lastError = error
                }
                if Self.reason(of: error).map(endsChainOn.contains) == true {
                    Self.logger.debug("Authenticator \(index + 1) ended the chain")
                    throw error
                }
            }

            if libssh2_userauth_authenticated(session) != 0 {
                Self.logger.info("Authentication succeeded after \(index + 1) step(s)")
                return
            }
        }

        if libssh2_userauth_authenticated(session) == 0 {
            throw lastError ?? SSHTunnelError.authenticationFailed(reason: .generic)
        }
    }

    private static func describesAnAttempt(_ error: any Error) -> Bool {
        reason(of: error)?.describesAnAttempt ?? true
    }

    private static func reason(of error: any Error) -> AuthFailureReason? {
        guard let tunnelError = error as? SSHTunnelError,
              case .authenticationFailed(let reason) = tunnelError else { return nil }
        return reason
    }
}
