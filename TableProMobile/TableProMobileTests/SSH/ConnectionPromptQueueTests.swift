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

    @Test("A question waits for the answer the user gives it")
    func answerResolvesTheWaiter() async {
        let queue = ConnectionPromptQueue()
        let prompt = makePrompt()

        async let answer = queue.confirm(prompt)
        while queue.current == nil { await Task.yield() }
        queue.answer(prompt.id, accepted: true)

        #expect(await answer == true)
        #expect(queue.current == nil)
    }

    @Test("Cancel answers no and leaves nothing on screen")
    func cancelResolvesToNo() async {
        let queue = ConnectionPromptQueue()
        let prompt = makePrompt()

        async let answer = queue.confirm(prompt)
        while queue.current == nil { await Task.yield() }
        queue.answer(prompt.id, accepted: false)

        #expect(await answer == false)
        #expect(queue.pending.isEmpty)
    }

    @Test("A question asked by a cancelled attempt is never shown")
    func alreadyCancelledAttemptAsksNothing() async {
        let queue = ConnectionPromptQueue()
        let task = Task { await queue.confirm(makePrompt()) }
        task.cancel()

        #expect(await task.value == false)
        #expect(queue.pending.isEmpty)
    }

    @Test("Cancelling the attempt while the question is up answers it")
    func cancellingWhileWaitingResolves() async {
        let queue = ConnectionPromptQueue()
        let task = Task { await queue.confirm(makePrompt()) }
        while queue.current == nil { await Task.yield() }

        task.cancel()

        #expect(await task.value == false)
        #expect(queue.pending.isEmpty)
    }

    @Test("Retiring the attempt answers every question it was waiting on")
    func cancelAllResolvesEveryWaiter() async {
        let queue = ConnectionPromptQueue()
        let first = makePrompt("First")
        let second = makePrompt("Second")

        async let firstAnswer = queue.confirm(first)
        async let secondAnswer = queue.confirm(second)
        while queue.pending.count < 2 { await Task.yield() }

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

        async let firstAnswer = queue.confirm(first)
        async let secondAnswer = queue.confirm(second)
        while queue.pending.count < 2 { await Task.yield() }

        #expect(queue.current?.id == first.id)
        queue.answer(first.id, accepted: true)
        #expect(queue.current?.id == second.id)
        queue.answer(second.id, accepted: true)

        #expect(await firstAnswer == true)
        #expect(await secondAnswer == true)
    }

    @Test("A notice can never answer a question, because it has no no")
    func noticeIsRefusedAsAQuestion() async {
        let queue = ConnectionPromptQueue()
        let notice = ConnectionPrompt(
            title: "Finish Signing In",
            message: "code",
            confirmTitle: "OK",
            style: .notice
        )

        #expect(await queue.confirm(notice) == false)
        #expect(queue.pending.isEmpty)
    }

    @Test("A notice needs no waiter and clears when it is acknowledged")
    func noticeClearsOnAcknowledgement() {
        let queue = ConnectionPromptQueue()
        let notice = ConnectionPrompt(
            title: "Finish Signing In",
            message: "code",
            confirmTitle: "OK",
            style: .notice
        )

        queue.notify(notice)
        #expect(queue.current?.id == notice.id)

        queue.answer(notice.id, accepted: true)
        #expect(queue.pending.isEmpty)
    }
}
