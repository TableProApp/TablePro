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

/// Context passed through the libssh2 session abstract pointer to the C callback.
///
/// TOTP codes are fetched lazily inside the callback (not upfront) so that:
///  - `AutoTOTPProvider` generates a code that's still valid when PAM validates it. The
///    upfront approach raced the 30-second window during the SSH handshake.
///  - When the server retries the kbd-int session after a wrong code (PAM defaults to
///    3 prompts), each retry calls `provideCode(attempt:)` again, matching how OpenSSH
///    re-prompts the user.
internal final class KeyboardInteractiveContext {
    let password: String?
    let totpProvider: (any TOTPProvider)?
    var totpAttemptCount: Int = 0
    var lastTotpError: Error?

    init(password: String?, totpProvider: (any TOTPProvider)?) {
        self.password = password
        self.totpProvider = totpProvider
    }

    /// Fetches the next TOTP code. Errors from the provider (user cancelled, missing
    /// secret) are stored in `lastTotpError` and surface at the end of the kbd-int session.
    /// The C callback can't throw across the libssh2 boundary, so we record the failure
    /// and report it after `libssh2_userauth_keyboard_interactive_ex` returns.
    func nextTotpCode() -> String {
        guard let totpProvider else { return "" }
        defer { totpAttemptCount += 1 }
        do {
            return try totpProvider.provideCode(attempt: totpAttemptCount)
        } catch {
            lastTotpError = error
            return ""
        }
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
            let buffer = UnsafeBufferPointer(start: textPtr, count: Int(prompt.length))
            promptText = String(decoding: buffer, as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
        } else {
            promptText = ""
        }

        let promptType = KeyboardInteractiveAuthenticator.classifyPrompt(promptText)

        let responseText: String
        switch promptType {
        case .password:
            responseText = context.password ?? ""
        case .totp:
            responseText = context.nextTotpCode()
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
        // Hand the provider to the callback so it can fetch a fresh code on every challenge
        // (see KeyboardInteractiveContext doc comment for why this isn't done upfront).
        let context = KeyboardInteractiveContext(password: password, totpProvider: totpProvider)
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

        // Surface a totpProvider error (e.g. user cancelled the NSAlert) verbatim. It's
        // already an SSHTunnelError with the right reason.
        if let providerError = context.lastTotpError {
            throw providerError
        }

        guard rc == 0 else {
            var msgPtr: UnsafeMutablePointer<CChar>?
            var msgLen: Int32 = 0
            libssh2_session_last_error(session, &msgPtr, &msgLen, 0)
            let detail = msgPtr.map { String(cString: $0) } ?? "Unknown error"
            Self.logger.error("Keyboard-interactive authentication failed: \(detail)")
            // If a TOTP code was actually delivered to the server, the rejection is most
            // likely about that code. Point the user at the authenticator, not the password.
            let reason: AuthFailureReason = context.totpAttemptCount > 0 ? .verificationCode : .password
            throw SSHTunnelError.authenticationFailed(reason: reason)
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
