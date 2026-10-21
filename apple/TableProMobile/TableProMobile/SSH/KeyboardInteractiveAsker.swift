import Foundation
import os
import TableProDatabase
import TableProModels
import TableProSSHTransport

// What answers the keyboard-interactive step that follows a first method, as on the Mac.
nonisolated struct KeyboardInteractiveCredentials: Sendable {
    let password: String?
    let totp: (any TOTPProvider)?
    let prompter: (any ConnectionPrompter)?

    init(password: String?, totp: (any TOTPProvider)?, prompter: (any ConnectionPrompter)?) {
        self.password = password
        self.totp = totp
        self.prompter = prompter
    }

    init(password: String?, config: SSHConfiguration, totpSecret: String?, prompter: (any ConnectionPrompter)?) {
        self.init(password: password, totp: Self.totp(config: config, secret: totpSecret), prompter: prompter)
    }

    // Prompt at Connect, or Auto Generate with no secret on this device, leaves the code to the user.
    static func totp(config: SSHConfiguration, secret: String?) -> (any TOTPProvider)? {
        guard config.totpMode.flatMap(TOTPMode.init(rawValue:)) == .autoGenerate,
              let secret,
              let generator = TOTPGenerator.fromBase32Secret(
                  secret,
                  algorithm: (config.totpAlgorithm.flatMap(TOTPAlgorithm.init(rawValue:)) ?? .sha1).toGeneratorAlgorithm,
                  digits: config.totpDigits ?? 6,
                  period: config.totpPeriod ?? 30
              ) else {
            return nil
        }
        return AutoTOTPProvider(generator: generator)
    }
}

// libssh2 asks from inside a C callback on the session queue, so the answer comes back through a
// semaphore while a task puts the question to the prompter on the main actor.
nonisolated final class KeyboardInteractiveAsker: Sendable {
    private struct State: Sendable {
        var cancelled = false
        var waiting: Waiting?
    }

    private struct Waiting: Sendable {
        let task: Task<Void, Never>
        let semaphore: DispatchSemaphore
    }

    private let prompter: any ConnectionPrompter
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(prompter: any ConnectionPrompter) {
        self.prompter = prompter
    }

    // Blocks the calling thread, which must not be the main thread, until the user answers or the
    // sign-in is cancelled.
    func ask(_ challenge: KeyboardInteractiveChallenge) -> [String]? {
        let semaphore = DispatchSemaphore(value: 0)
        let reply = OSAllocatedUnfairLock<[String]?>(initialState: nil)
        let prompter = self.prompter
        let started = state.withLock { state -> Bool in
            guard !state.cancelled else { return false }
            let task = Task { @MainActor in
                let answers = await prompter.answer(challenge)
                reply.withLock { $0 = answers }
                semaphore.signal()
            }
            state.waiting = Waiting(task: task, semaphore: semaphore)
            return true
        }
        guard started else { return nil }
        semaphore.wait()
        return state.withLock { state -> [String]? in
            state.waiting = nil
            return state.cancelled ? nil : reply.withLock { $0 }
        }
    }

    func cancel() {
        let waiting = state.withLock { state -> Waiting? in
            state.cancelled = true
            defer { state.waiting = nil }
            return state.waiting
        }
        waiting?.task.cancel()
        waiting?.semaphore.signal()
    }
}
