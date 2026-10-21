import Foundation
import os
import TableProDatabase
import TableProSSHTransport
import Testing

@testable import TableProMobile

@Suite("Keyboard-interactive asker", .timeLimit(.minutes(1)))
struct KeyboardInteractiveAskerTests {
    private let challenge = KeyboardInteractiveChallenge(
        name: "",
        instruction: "",
        prompts: [KeyboardInteractivePrompt(text: "Verification code: ", echo: true)]
    )

    // The asker blocks its thread the way libssh2's callback does, so it runs off the main actor.
    private func askOffMain(_ asker: KeyboardInteractiveAsker) async -> [String]? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: asker.ask(challenge))
            }
        }
    }

    @Test("The session queue waits for the prompter's answer")
    func returnsThePromptersAnswer() async {
        let asker = KeyboardInteractiveAsker(prompter: ScriptedChallengePrompter(reply: ["424242"]))

        #expect(await askOffMain(asker) == ["424242"])
    }

    @Test("A cancelled sign-in ends the wait with no answer, even while the question is up")
    func cancelEndsTheWait() async {
        let prompter = ScriptedChallengePrompter(reply: nil, hangs: true)
        let asker = KeyboardInteractiveAsker(prompter: prompter)

        async let answer = askOffMain(asker)
        await prompter.waitUntilAsked()
        asker.cancel()

        #expect(await answer == nil)
    }

    @Test("Once cancelled, a later question is not put to the user")
    func cancelledAskerAsksNothing() async {
        let prompter = ScriptedChallengePrompter(reply: ["unused"])
        let asker = KeyboardInteractiveAsker(prompter: prompter)
        asker.cancel()

        #expect(await askOffMain(asker) == nil)
        #expect(prompter.askCount == 0)
    }
}

nonisolated final class ScriptedChallengePrompter: ConnectionPrompter, Sendable {
    private let reply: [String]?
    private let hangs: Bool
    private let asks = OSAllocatedUnfairLock(initialState: 0)

    init(reply: [String]?, hangs: Bool = false) {
        self.reply = reply
        self.hangs = hangs
    }

    var askCount: Int { asks.withLock { $0 } }
    var answersChallenges: Bool { true }

    func confirm(_ question: ConnectionQuestion) async -> Bool { true }

    func answer(_ challenge: KeyboardInteractiveChallenge) async -> [String]? {
        asks.withLock { $0 += 1 }
        if hangs {
            try? await Task.sleep(for: .seconds(30))
        }
        return reply
    }

    func waitUntilAsked() async {
        while askCount == 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
