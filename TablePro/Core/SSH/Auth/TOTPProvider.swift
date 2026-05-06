//
//  TOTPProvider.swift
//  TablePro
//

import Foundation

/// Protocol for providing TOTP verification codes
internal protocol TOTPProvider: Sendable {
    /// Generate or obtain a TOTP code.
    /// - Parameter attempt: 0 for the first prompt in a session, 1+ for retries when the
    ///   server rejected an earlier code (wrong digits, expired window). Implementations
    ///   may use this to vary UI affordances. `PromptTOTPProvider` shows a "previous code
    ///   was rejected" hint when `attempt > 0`.
    /// - Returns: The TOTP code string.
    /// - Throws: `SSHTunnelError` if the code cannot be obtained (user cancelled, no secret).
    func provideCode(attempt: Int) throws -> String
}

extension TOTPProvider {
    /// Convenience for callers that only ever need a single code (test connections, sync probes).
    func provideCode() throws -> String { try provideCode(attempt: 0) }
}

/// Automatically generates TOTP codes from a stored secret.
///
/// If the current code expires in less than 5 seconds, waits for the next
/// period to avoid submitting a code that expires during the authentication handshake.
/// The maximum wait is ~6 seconds (bounded).
internal struct AutoTOTPProvider: TOTPProvider {
    let generator: TOTPGenerator

    func provideCode(attempt: Int) throws -> String {
        let remaining = generator.secondsRemaining()
        if remaining < 5 {
            // Brief bounded sleep (max ~6s) to wait for next TOTP period.
            // Uses usleep to avoid blocking a GCD worker thread via Thread.sleep.
            usleep(UInt32((remaining + 1) * 1_000_000))
        }
        return generator.generate()
    }
}
