//
//  TOTPProvider.swift
//  TablePro
//

import Foundation

/// Protocol for providing TOTP verification codes
internal protocol TOTPProvider: Sendable {
    /// Generate or obtain a TOTP code
    /// - Returns: The TOTP code string
    /// - Throws: SSHTunnelError if the code cannot be obtained
    func provideCode() throws -> String
}

/// Automatically generates TOTP codes from a stored secret.
///
/// If the current code expires in less than 5 seconds, waits for the next
/// period to avoid submitting a code that expires during the authentication handshake.
/// The maximum wait is ~6 seconds (bounded).
internal struct AutoTOTPProvider: TOTPProvider {
    let generator: TOTPGenerator

    func provideCode() throws -> String {
        let remaining = generator.secondsRemaining()
        if remaining < 5 {
            // Brief bounded sleep (max ~6s) to wait for next TOTP period.
            // Uses usleep to avoid blocking a GCD worker thread via Thread.sleep.
            usleep(UInt32((remaining + 1) * 1_000_000))
        }
        return generator.generate()
    }
}
