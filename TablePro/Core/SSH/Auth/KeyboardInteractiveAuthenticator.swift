//
//  KeyboardInteractiveAuthenticator.swift
//  TablePro
//

import Foundation
import os

import CLibSSH2

/// How a keyboard-interactive prompt should be answered without asking the user.
///
/// The classification is a fast-path hint only: it decides when a pre-known credential (the SSH
/// password, an auto-generated TOTP code) can answer a prompt. Anything not claimed here defers to
/// the interactive prompt, so a weak keyword match is a missed shortcut, not a wrong answer.
internal enum KBDINTPromptType: Equatable {
    case password
    case totp
    case unmatched
}

/// Context reached from the C callback through the libssh2 session abstract pointer.
///
/// TOTP codes and user prompts are resolved lazily inside the callback (not upfront) so that a
/// generated code is still valid when PAM checks it, and so the server can re-prompt within one
/// session (PAM defaults to 3 attempts) with each retry driving a fresh code or dialog. The C
/// callback can't throw across the libssh2 boundary, so failures and cancellation are recorded here
/// and surface after `libssh2_userauth_keyboard_interactive_ex` returns.
internal final class KeyboardInteractiveContext {
    let password: String?
    let totpProvider: (any TOTPProvider)?
    let promptProvider: any KeyboardInteractivePromptProvider
    private(set) var totpAttemptCount = 0
    private(set) var interactiveAttemptCount = 0
    private(set) var userCancelled = false
    var lastError: Error?

    init(
        password: String?,
        totpProvider: (any TOTPProvider)?,
        promptProvider: any KeyboardInteractivePromptProvider
    ) {
        self.password = password
        self.totpProvider = totpProvider
        self.promptProvider = promptProvider
    }

    func nextTotpCode() -> String {
        guard let totpProvider else { return "" }
        defer { totpAttemptCount += 1 }
        do {
            return try totpProvider.provideCode(attempt: totpAttemptCount)
        } catch {
            lastError = error
            return ""
        }
    }

    /// Resolve one response per prompt. Known prompts are answered from the password / TOTP
    /// fast path; the rest go to the interactive prompt in a single dialog. Every index is filled
    /// (empty string on cancel) so libssh2 never frees an unset response.
    func responses(name: String, instruction: String, prompts: [KeyboardInteractivePrompt]) -> [String] {
        var results = [String?](repeating: nil, count: prompts.count)
        var pendingIndices: [Int] = []

        for (index, prompt) in prompts.enumerated() {
            switch KeyboardInteractiveAuthenticator.classify(prompt.text) {
            case .password where password != nil:
                results[index] = password
            case .totp where totpProvider != nil:
                results[index] = nextTotpCode()
            default:
                pendingIndices.append(index)
            }
        }

        guard !pendingIndices.isEmpty, !userCancelled else {
            return results.map { $0 ?? "" }
        }

        let challenge = KeyboardInteractiveChallenge(
            name: name,
            instruction: instruction,
            prompts: pendingIndices.map { prompts[$0] }
        )

        do {
            let answers = try promptProvider.provideResponses(for: challenge, attempt: interactiveAttemptCount)
            interactiveAttemptCount += 1
            guard answers.count == pendingIndices.count else {
                userCancelled = true
                lastError = SSHTunnelError.authenticationFailed(reason: .cancelled)
                return results.map { $0 ?? "" }
            }
            for (offset, index) in pendingIndices.enumerated() {
                results[index] = answers[offset]
            }
        } catch {
            userCancelled = true
            lastError = error
        }

        return results.map { $0 ?? "" }
    }
}

/// C-compatible callback for libssh2 keyboard-interactive authentication.
///
/// libssh2 invokes this synchronously for each challenge. Responses are allocated with `strdup`
/// because libssh2 `free`s them, and every slot is filled even on cancel.
private let kbdintCallback: @convention(c) (
    UnsafePointer<CChar>?, Int32,
    UnsafePointer<CChar>?, Int32,
    Int32,
    UnsafePointer<LIBSSH2_USERAUTH_KBDINT_PROMPT>?,
    UnsafeMutablePointer<LIBSSH2_USERAUTH_KBDINT_RESPONSE>?,
    UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Void = { namePtr, nameLen, instructionPtr, instructionLen, numPrompts, prompts, responses, abstract in
    guard numPrompts > 0,
          let prompts,
          let responses,
          let abstract,
          let contextPtr = abstract.pointee else {
        return
    }

    let context = Unmanaged<KeyboardInteractiveContext>.fromOpaque(contextPtr)
        .takeUnretainedValue()

    let name = decodeKbdintString(namePtr, length: nameLen)
    let instruction = decodeKbdintString(instructionPtr, length: instructionLen)

    let decodedPrompts = (0..<Int(numPrompts)).map { index -> KeyboardInteractivePrompt in
        let prompt = prompts[index]
        let bytes: [UInt8]
        if let textPtr = prompt.text, prompt.length > 0 {
            bytes = Array(UnsafeBufferPointer(start: textPtr, count: Int(prompt.length)))
        } else {
            bytes = []
        }
        return KeyboardInteractivePrompt(utf8Bytes: bytes, echo: prompt.echo != 0)
    }

    let answers = context.responses(name: name, instruction: instruction, prompts: decodedPrompts)

    for index in 0..<Int(numPrompts) {
        let answer = index < answers.count ? answers[index] : ""
        let duplicated = strdup(answer) ?? strdup("")
        responses[index].text = duplicated
        responses[index].length = duplicated.map { UInt32(strlen($0)) } ?? 0
    }
}

private func decodeKbdintString(_ pointer: UnsafePointer<CChar>?, length: Int32) -> String {
    guard let pointer, length > 0 else { return "" }
    return pointer.withMemoryRebound(to: UInt8.self, capacity: Int(length)) { bytes in
        String(decoding: UnsafeBufferPointer(start: bytes, count: Int(length)), as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
    }
}

internal struct KeyboardInteractiveAuthenticator: SSHAuthenticator {
    private static let logger = Logger(
        subsystem: "com.TablePro",
        category: "KeyboardInteractiveAuthenticator"
    )

    let password: String?
    let totpProvider: (any TOTPProvider)?
    let promptProvider: any KeyboardInteractivePromptProvider

    func authenticate(session: OpaquePointer, username: String) throws {
        let context = KeyboardInteractiveContext(
            password: password,
            totpProvider: totpProvider,
            promptProvider: promptProvider
        )
        let contextPtr = Unmanaged.passRetained(context).toOpaque()

        defer {
            Unmanaged<KeyboardInteractiveContext>.fromOpaque(contextPtr).release()
        }

        let abstractPtr = libssh2_session_abstract(session)
        let previousAbstract = abstractPtr?.pointee
        abstractPtr?.pointee = contextPtr

        defer {
            abstractPtr?.pointee = previousAbstract
        }

        Self.logger.debug("Attempting keyboard-interactive authentication for \(username, privacy: .private)")

        let rc = libssh2_userauth_keyboard_interactive_ex(
            session,
            username, UInt32(username.utf8.count),
            kbdintCallback
        )

        if let providerError = context.lastError {
            throw providerError
        }

        guard rc == 0 else {
            var msgPtr: UnsafeMutablePointer<CChar>?
            var msgLen: Int32 = 0
            libssh2_session_last_error(session, &msgPtr, &msgLen, 0)
            let detail = msgPtr.map { String(cString: $0) } ?? "Unknown error"
            Self.logger.error("Keyboard-interactive authentication failed: \(detail)")
            let reason: AuthFailureReason = context.interactiveAttemptCount > 0
                ? .keyboardInteractive
                : (context.totpAttemptCount > 0 ? .verificationCode : .password)
            throw SSHTunnelError.authenticationFailed(reason: reason)
        }

        Self.logger.info("Keyboard-interactive authentication succeeded")
    }

    static func classify(_ promptText: String) -> KBDINTPromptType {
        let lower = promptText.lowercased()

        if lower.contains("verification") || lower.contains("code") ||
            lower.contains("otp") || lower.contains("token") ||
            lower.contains("totp") || lower.contains("2fa") ||
            lower.contains("one-time") || lower.contains("factor") {
            return .totp
        }

        if lower.contains("password") {
            return .password
        }

        return .unmatched
    }
}
