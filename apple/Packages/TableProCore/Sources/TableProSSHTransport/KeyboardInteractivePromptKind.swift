//
//  KeyboardInteractivePromptKind.swift
//  TableProSSHTransport
//

import Foundation

public enum KeyboardInteractivePromptKind: Equatable, Sendable {
    case password
    case totp
    case unmatched

    // The code words go first: "One-time password: " asks for a code, not the SSH password.
    public init(promptText: String) {
        let lower = promptText.lowercased()
        if Self.codeKeywords.contains(where: { lower.contains($0) }) {
            self = .totp
        } else if lower.contains("password") {
            self = .password
        } else {
            self = .unmatched
        }
    }

    private static let codeKeywords = ["verification", "code", "otp", "token", "totp", "2fa", "one-time", "factor"]
}
