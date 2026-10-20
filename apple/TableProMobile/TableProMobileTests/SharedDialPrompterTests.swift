import Foundation
import TableProDatabase
import TableProSSHTransport
@testable import TableProMobile
import Testing

@MainActor
struct SharedDialPrompterTests {
    private let question = ConnectionQuestion.unknownHostKey(host: "bastion.example.com", port: 22, keyType: "ED25519", fingerprint: "SHA256:abc")

    private func waitForPrompt(on queue: ConnectionPromptQueue) async {
        while queue.current == nil { await Task.yield() }
    }

    // The window that started the dial closes the way `retire()` does: its queue answers no, then it leaves.
    @Test("A question the closing window was asked moves to the window still waiting on the dial")
    func questionMovesToTheWaitingWindow() async throws {
        let starter = ConnectionPromptQueue()
        let joiner = ConnectionPromptQueue()
        let starterWindow = NSObject()
        let joinerWindow = NSObject()
        let shared = SharedDialPrompter()
        shared.add(ObjectIdentifier(starterWindow), starter)
        shared.add(ObjectIdentifier(joinerWindow), joiner)

        let answer = Task { await shared.confirm(question) }
        await waitForPrompt(on: starter)
        starter.cancelAll()
        shared.remove(ObjectIdentifier(starterWindow))
        await waitForPrompt(on: joiner)
        joiner.answer(try #require(joiner.current).id, accepted: true)

        #expect(await answer.value)
        withExtendedLifetime(joinerWindow) {}
    }

    @Test("A no from a window still on the dial ends the question there")
    func declineEndsTheQuestion() async throws {
        let first = ConnectionPromptQueue()
        let second = ConnectionPromptQueue()
        let firstWindow = NSObject()
        let secondWindow = NSObject()
        let shared = SharedDialPrompter()
        shared.add(ObjectIdentifier(firstWindow), first)
        shared.add(ObjectIdentifier(secondWindow), second)

        let answer = Task { await shared.confirm(question) }
        await waitForPrompt(on: first)
        first.answer(try #require(first.current).id, accepted: false)

        #expect(await answer.value == false)
        #expect(second.current == nil)
    }

    @Test("A sign-in question the closing window was asked moves to the window still waiting, and a Cancel there ends it")
    func challengeMovesToTheWaitingWindow() async throws {
        let challenge = KeyboardInteractiveChallenge(
            name: "",
            instruction: "",
            prompts: [KeyboardInteractivePrompt(text: "Verification code: ", echo: true)]
        )
        let starter = ConnectionPromptQueue()
        let joiner = ConnectionPromptQueue()
        let starterWindow = NSObject()
        let joinerWindow = NSObject()
        let shared = SharedDialPrompter()
        shared.add(ObjectIdentifier(starterWindow), starter)
        shared.add(ObjectIdentifier(joinerWindow), joiner)
        #expect(shared.answersChallenges)

        let answered = Task { await shared.answer(challenge) }
        await waitForPrompt(on: starter)
        starter.cancelAll()
        shared.remove(ObjectIdentifier(starterWindow))
        await waitForPrompt(on: joiner)
        joiner.answer(try #require(joiner.current).id, accepted: true, typed: ["424242"])
        #expect(await answered.value == ["424242"])

        let cancelled = Task { await shared.answer(challenge) }
        await waitForPrompt(on: joiner)
        joiner.answer(try #require(joiner.current).id, accepted: false)
        #expect(await cancelled.value == nil)
        withExtendedLifetime(joinerWindow) {}
    }
}
