import Foundation
import TableProDatabase
import TableProSSHTransport
@testable import TableProMobile
import Testing

@MainActor
struct SharedDialPrompterTests {
    private let question = ConnectionQuestion.unknownHostKey(host: "bastion.example.com", port: 22, keyType: "ED25519", fingerprint: "SHA256:abc")

    // Bounded, so a question that never reaches the queue fails the test instead of hanging the suite.
    private func waitForPrompt(on queue: ConnectionPromptQueue) async {
        for _ in 0 ..< 1_000 where queue.current == nil {
            await Task.yield()
        }
        #expect(queue.current != nil, "the question should reach this window")
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

    // The screen closes before the window's attempt is cancelled, so its queue answers no while it is still on the dial.
    @Test("A question the closed screen was asked moves to the window still waiting before the window leaves")
    func closedScreenPassesTheQuestionOn() async throws {
        let starter = ConnectionPromptQueue()
        let joiner = ConnectionPromptQueue()
        starter.screenAppeared()
        joiner.screenAppeared()
        let starterWindow = NSObject()
        let joinerWindow = NSObject()
        let shared = SharedDialPrompter()
        shared.add(ObjectIdentifier(starterWindow), starter)
        shared.add(ObjectIdentifier(joinerWindow), joiner)

        let answer = Task { await shared.confirm(question) }
        await waitForPrompt(on: starter)
        starter.screenDisappeared()
        await waitForPrompt(on: joiner)
        joiner.answer(try #require(joiner.current).id, accepted: true)

        #expect(await answer.value)
        withExtendedLifetime((starterWindow, joinerWindow)) {}
    }

    @Test("A window whose screen comes back is asked the next question once the window that took the last one leaves")
    func reopenedScreenIsAskedAgain() async throws {
        let first = ConnectionPromptQueue()
        let second = ConnectionPromptQueue()
        first.screenAppeared()
        second.screenAppeared()
        let firstWindow = NSObject()
        let secondWindow = NSObject()
        let shared = SharedDialPrompter()
        shared.add(ObjectIdentifier(firstWindow), first)
        shared.add(ObjectIdentifier(secondWindow), second)

        let answer = Task { await shared.confirm(question) }
        await waitForPrompt(on: first)
        first.screenDisappeared()
        await waitForPrompt(on: second)
        first.screenAppeared()
        second.answer(try #require(second.current).id, accepted: true)
        #expect(await answer.value)

        shared.remove(ObjectIdentifier(secondWindow))
        let challenge = KeyboardInteractiveChallenge(
            name: "",
            instruction: "",
            prompts: [KeyboardInteractivePrompt(text: "Verification code: ", echo: true)]
        )
        let answered = Task { await shared.answer(challenge) }
        await waitForPrompt(on: first)
        first.answer(try #require(first.current).id, accepted: true, typed: ["424242"])

        #expect(await answered.value == ["424242"])
        withExtendedLifetime((firstWindow, secondWindow)) {}
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
