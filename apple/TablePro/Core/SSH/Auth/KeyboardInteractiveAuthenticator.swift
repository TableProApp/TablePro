//
//  KeyboardInteractiveAuthenticator.swift
//  TablePro
//

import Foundation
import os

import CLibSSH2
import TableProSSHConfig
import TableProSSHTransport

// Codes and prompts resolve inside the callback, so a code is still valid when PAM checks it and each re-prompt gets a fresh one.
// The C callback cannot throw, so errors and cancellation wait here until libssh2 returns.
internal final class KeyboardInteractiveContext {
    let password: String?
    let totpProvider: (any TOTPProvider)?
    let promptProvider: any KeyboardInteractivePromptProvider
    private(set) var totpAttemptCount = 0
    private(set) var interactiveAttemptCount = 0
    private(set) var passwordAnswerCount = 0
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

    // A server that sent no prompt never took a credential, so the method was not on offer.
    var failureReason: AuthFailureReason {
        if interactiveAttemptCount > 0 { return .keyboardInteractive }
        if totpAttemptCount > 0 { return .verificationCode }
        if passwordAnswerCount > 0 { return .password }
        return .methodUnavailable
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

    // Every slot gets a string, empty on cancel, since libssh2 frees each response.
    func responses(name: String, instruction: String, prompts: [KeyboardInteractivePrompt]) -> [String] {
        var results = [String?](repeating: nil, count: prompts.count)
        var pendingIndices: [Int] = []

        for (index, prompt) in prompts.enumerated() {
            switch KeyboardInteractiveAuthenticator.classify(prompt.text) {
            case .password where password != nil:
                results[index] = password
                passwordAnswerCount += 1
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

// strdup because libssh2 frees each response.
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
            throw SSHTunnelError.authenticationFailed(reason: context.failureReason)
        }

        Self.logger.info("Keyboard-interactive authentication succeeded")
    }

    static func classify(_ promptText: String) -> KeyboardInteractivePromptKind {
        KeyboardInteractivePromptKind(promptText: promptText)
    }
}
