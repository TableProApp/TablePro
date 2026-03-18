//
//  KeyboardInteractiveAuthenticator.swift
//  TablePro
//

import Foundation
import os

import CLibSSH2

/// Prompt type classification for keyboard-interactive authentication
internal enum KBDINTPromptType {
    case password
    case totp
    case unknown
}

/// Context passed through the libssh2 session abstract pointer to the C callback
internal final class KeyboardInteractiveContext {
    var password: String?
    var totpCode: String?

    init(password: String?, totpCode: String?) {
        self.password = password
        self.totpCode = totpCode
    }
}

/// C-compatible callback for libssh2 keyboard-interactive authentication.
///
/// libssh2 calls this for each authentication challenge. The context (password/TOTP code)
/// is retrieved from the session abstract pointer. Responses are allocated with `strdup`
/// because libssh2 will `free` them.
private let kbdintCallback: @convention(c) (
    UnsafePointer<CChar>?, Int32,
    UnsafePointer<CChar>?, Int32,
    Int32,
    UnsafePointer<LIBSSH2_USERAUTH_KBDINT_PROMPT>?,
    UnsafeMutablePointer<LIBSSH2_USERAUTH_KBDINT_RESPONSE>?,
    UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Void = { _, _, _, _, numPrompts, prompts, responses, abstract in
    guard numPrompts > 0,
          let prompts,
          let responses,
          let abstract,
          let contextPtr = abstract.pointee else {
        return
    }

    let context = Unmanaged<KeyboardInteractiveContext>.fromOpaque(contextPtr)
        .takeUnretainedValue()

    for i in 0..<Int(numPrompts) {
        let prompt = prompts[i]
        let promptText: String
        if let textPtr = prompt.text, prompt.length > 0 {
            promptText = String(
                bytesNoCopy: UnsafeMutableRawPointer(mutating: textPtr),
                length: Int(prompt.length),
                encoding: .utf8,
                freeWhenDone: false
            ) ?? ""
        } else {
            promptText = ""
        }

        let promptType = KeyboardInteractiveAuthenticator.classifyPrompt(promptText)

        let responseText: String
        switch promptType {
        case .password:
            responseText = context.password ?? ""
        case .totp:
            responseText = context.totpCode ?? ""
        case .unknown:
            // Fall back to password for unrecognized prompts
            responseText = context.password ?? ""
        }

        let duplicated = strdup(responseText) ?? strdup("")
        responses[i].text = duplicated
        responses[i].length = duplicated.map { UInt32(strlen($0)) } ?? 0
    }
}

internal struct KeyboardInteractiveAuthenticator: SSHAuthenticator {
    private static let logger = Logger(
        subsystem: "com.TablePro",
        category: "KeyboardInteractiveAuthenticator"
    )

    let password: String?
    let totpProvider: (any TOTPProvider)?

    func authenticate(session: OpaquePointer, username: String) throws {
        // Generate TOTP code if a provider is available
        let totpCode: String?
        if let totpProvider {
            totpCode = try totpProvider.provideCode()
        } else {
            totpCode = nil
        }

        // Create context and store in session abstract pointer
        let context = KeyboardInteractiveContext(password: password, totpCode: totpCode)
        let contextPtr = Unmanaged.passRetained(context).toOpaque()

        defer {
            // Balance the passRetained call
            Unmanaged<KeyboardInteractiveContext>.fromOpaque(contextPtr).release()
        }

        // Store context pointer in the session's abstract field
        let abstractPtr = libssh2_session_abstract(session)
        let previousAbstract = abstractPtr?.pointee
        abstractPtr?.pointee = contextPtr

        defer {
            // Restore previous abstract value
            abstractPtr?.pointee = previousAbstract
        }

        Self.logger.debug("Attempting keyboard-interactive authentication for \(username, privacy: .private)")

        let rc = libssh2_userauth_keyboard_interactive_ex(
            session,
            username, UInt32(username.utf8.count),
            kbdintCallback
        )

        guard rc == 0 else {
            Self.logger.error("Keyboard-interactive authentication failed (rc=\(rc))")
            throw SSHTunnelError.authenticationFailed
        }

        Self.logger.info("Keyboard-interactive authentication succeeded")
    }

    /// Classify a keyboard-interactive prompt to determine which credential to supply
    static func classifyPrompt(_ promptText: String) -> KBDINTPromptType {
        let lower = promptText.lowercased()

        if lower.contains("password") {
            return .password
        }

        if lower.contains("verification") || lower.contains("code") ||
            lower.contains("otp") || lower.contains("token") ||
            lower.contains("totp") || lower.contains("2fa") ||
            lower.contains("one-time") || lower.contains("factor") {
            return .totp
        }

        return .unknown
    }
}
