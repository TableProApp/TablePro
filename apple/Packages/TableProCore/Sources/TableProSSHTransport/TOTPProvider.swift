//
//  TOTPProvider.swift
//  TablePro
//

import Foundation

public protocol TOTPProvider: Sendable {
    /// Generate or obtain a TOTP code.
    /// - Parameter attempt: 0 for the first code in a session, 1+ for retries when the
    ///   server rejected an earlier code (wrong digits, expired window).
    /// - Returns: The TOTP code string.
    /// - Throws: `SSHTunnelError` if the code cannot be obtained (user cancelled, no secret).
    func provideCode(attempt: Int) throws -> String
}

public extension TOTPProvider {
    /// Convenience for callers that only ever need a single code (test connections, sync probes).
    func provideCode() throws -> String { try provideCode(attempt: 0) }
}

/// If the current code expires in less than 5 seconds, waits for the next
/// period to avoid submitting a code that expires during the authentication handshake.
/// The maximum wait is ~6 seconds (bounded).
public struct AutoTOTPProvider: TOTPProvider {
    let generator: TOTPGenerator

    public init(generator: TOTPGenerator) {
        self.generator = generator
    }

    public func provideCode(attempt: Int) throws -> String {
        let remaining = generator.secondsRemaining()
        if remaining < 5 {
            // Brief bounded sleep (max ~6s) to wait for next TOTP period.
            // Uses usleep to avoid blocking a GCD worker thread via Thread.sleep.
            usleep(UInt32((remaining + 1) * 1_000_000))
        }
        return generator.generate()
    }
}
