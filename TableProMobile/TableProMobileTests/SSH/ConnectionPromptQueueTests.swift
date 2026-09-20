import Foundation
import TableProDatabase
@testable import TableProMobile
import Testing

@MainActor
@Suite("Connection prompt queue")
struct ConnectionPromptQueueTests {
    private func makePrompt(_ title: String = "Unknown SSH Server") -> ConnectionPrompt {
        ConnectionPrompt(title: title, message: "fingerprint", confirmTitle: "Trust")
    }

    private func makeNotice() -> ConnectionPrompt {
        ConnectionPrompt(
            title: "Finish Signing In",
            message: "code",
            confirmTitle: "OK",
            style: .notice
        )
    }

    private func question() -> ConnectionQuestion {
        .unknownHostKey(host: "db.example.com", port: 22, keyType: "ssh-ed25519", fingerprint: "SHA256:abc")
    }

    /// Bounded, so a regression fails the test instead of hanging the suite on the main actor.
    private func waitUntil(_ condition: () -> Bool, _ comment: Comment) async {
        for _ in 0 ..< 1_000 where !condition() {
            await Task.yield()
        }
        #expect(condition(), comment)
    }

    @Test("A question waits for the answer the user gives it")
    func answerResolvesTheWaiter() async {
        let queue = ConnectionPromptQueue()
        let prompt = makePrompt()

        async let answer = queue.ask(prompt)
        await waitUntil({ queue.current != nil }, "the question should be on screen")
        queue.answer(prompt.id, accepted: true)

        #expect(await answer == true)
        #expect(queue.current == nil)
    }

    @Test("Cancel answers no and leaves nothing on screen")
    func cancelResolvesToNo() async {
        let queue = ConnectionPromptQueue()
        let prompt = makePrompt()

        async let answer = queue.ask(prompt)
        await waitUntil({ queue.current != nil }, "the question should be on screen")
        queue.answer(prompt.id, accepted: false)

        #expect(await answer == false)
        #expect(queue.pending.isEmpty)
    }

    @Test("A question asked by a cancelled attempt is never shown")
    func alreadyCancelledAttemptAsksNothing() async {
        let queue = ConnectionPromptQueue()
        let task = Task { await queue.ask(makePrompt()) }
        task.cancel()

        #expect(await task.value == false)
        #expect(queue.pending.isEmpty)
    }

    @Test("Cancelling the attempt while the question is up answers it")
    func cancellingWhileWaitingResolves() async {
        let queue = ConnectionPromptQueue()
        let task = Task { await queue.ask(makePrompt()) }
        await waitUntil({ queue.current != nil }, "the question should be on screen")

        task.cancel()

        #expect(await task.value == false)
        #expect(queue.pending.isEmpty)
    }

    @Test("Retiring the attempt answers every question it was waiting on")
    func cancelAllResolvesEveryWaiter() async {
        let queue = ConnectionPromptQueue()

        async let firstAnswer = queue.ask(makePrompt("First"))
        async let secondAnswer = queue.ask(makePrompt("Second"))
        await waitUntil({ queue.pending.count == 2 }, "both questions should be queued")

        queue.cancelAll()

        #expect(await firstAnswer == false)
        #expect(await secondAnswer == false)
        #expect(queue.pending.isEmpty)
    }

    @Test("A second question waits its turn instead of being refused")
    func secondQuestionIsQueued() async {
        let queue = ConnectionPromptQueue()
        let first = makePrompt("First")
        let second = makePrompt("Second")

        async let firstAnswer = queue.ask(first)
        async let secondAnswer = queue.ask(second)
        await waitUntil({ queue.pending.count == 2 }, "both questions should be queued")

        #expect(queue.current?.id == first.id)
        queue.answer(first.id, accepted: true)
        #expect(queue.current?.id == second.id)
        queue.answer(second.id, accepted: true)

        #expect(await firstAnswer == true)
        #expect(await secondAnswer == true)
    }

    @Test("A host key question reads as the server, its key type and its fingerprint")
    func questionIsRenderedForTheUser() async {
        let queue = ConnectionPromptQueue()

        async let answer = queue.confirm(question())
        await waitUntil({ queue.current != nil }, "the question should be on screen")

        let prompt = queue.current
        #expect(prompt?.message.contains("[db.example.com]:22") == true)
        #expect(prompt?.message.contains("SHA256:abc") == true)
        #expect(prompt?.style == .standard)

        queue.answer(prompt?.id ?? UUID(), accepted: false)
        #expect(await answer == false)
    }

    @Test("A changed host key asks with the destructive action")
    func changedKeyQuestionIsDestructive() async {
        let queue = ConnectionPromptQueue()
        let changed = ConnectionQuestion.changedHostKey(
            host: "db.example.com",
            port: 22,
            previousFingerprint: "SHA256:old",
            currentFingerprint: "SHA256:new"
        )

        async let answer = queue.confirm(changed)
        await waitUntil({ queue.current != nil }, "the question should be on screen")

        #expect(queue.current?.style == .destructive)
        queue.answer(queue.current?.id ?? UUID(), accepted: false)
        #expect(await answer == false)
    }

    @Test("A notice can never answer a question, because it has no no")
    func noticeIsRefusedAsAQuestion() async {
        let queue = ConnectionPromptQueue()

        #expect(await queue.ask(makeNotice()) == false)
        #expect(queue.pending.isEmpty)
    }

    @Test("A notice needs no waiter and clears when it is acknowledged")
    func noticeClearsOnAcknowledgement() {
        let queue = ConnectionPromptQueue()
        let notice = makeNotice()

        queue.notify(notice, generation: queue.generation)
        #expect(queue.current?.id == notice.id)

        queue.answer(notice.id, accepted: true)
        #expect(queue.pending.isEmpty)
    }

    @Test("A notice from an abandoned attempt never reaches the next one")
    func staleNoticeIsDropped() {
        let queue = ConnectionPromptQueue()
        let generation = queue.generation

        queue.cancelAll()
        queue.notify(makeNotice(), generation: generation)

        #expect(queue.pending.isEmpty)
    }
}
