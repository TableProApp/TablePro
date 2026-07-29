//
//  KeyboardInteractivePromptProvider.swift
//  TablePro
//

import Foundation

/// Supplies responses for a keyboard-interactive challenge the SSH server issues mid-handshake.
///
/// One response per prompt, in the challenge's prompt order. Implementations throw when the user
/// declines to answer (cancelled), which aborts the authentication chain instead of silently
/// trying the next method.
internal protocol KeyboardInteractivePromptProvider: Sendable {
    func provideResponses(for challenge: KeyboardInteractiveChallenge, attempt: Int) throws -> [String]
}
