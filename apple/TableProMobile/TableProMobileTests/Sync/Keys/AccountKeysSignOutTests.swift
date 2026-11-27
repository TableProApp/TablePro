import Foundation
import TableProFFI
@testable import TableProMobile
import TableProTestSupport
import Testing

@MainActor
struct AccountKeysSignOutTests {
    private static func signOut(
        _ flows: FakeAccountKeyFlows,
        answers: [AccountKeysSignOutAnswer],
        asked: @escaping (String) -> Void = { _ in }
    ) -> AccountKeysSignOut {
        var remaining = answers
        return AccountKeysSignOut.over({ flows }) { reason in
            asked(reason)
            return remaining.isEmpty ? .cancel : remaining.removeFirst()
        }
    }

    @Test("The keys are erased before the sign-in goes, and nothing is asked when that works")
    func erasesFirst() async {
        let flows = FakeAccountKeyFlows()
        var asked: [String] = []
        let keys = Self.signOut(flows, answers: []) { asked.append($0) }

        let proceeds = await keys.signOut { true }

        #expect(proceeds)
        #expect(flows.calls(named: "signOutKeys").count == 1)
        #expect(asked.isEmpty)
    }

    @Test("A failed erase asks, and Try Again goes to the same service until it works")
    func retryAfterFailure() async {
        let flows = FakeAccountKeyFlows()
        flows.fail("signOutKeys", with: FakeAccountKeyFlows.failure("sync.network"))
        var asked: [String] = []
        let keys = Self.signOut(flows, answers: [.retry]) { asked.append($0) }

        let proceeds = await keys.signOut { true }

        #expect(proceeds)
        #expect(asked == [AccountKeysText.message(code: "sync.network")])
        #expect(flows.calls(named: "signOutKeys").count == 2)
    }

    @Test("Cancel keeps the sign-in, and Sign Out Anyway goes on only while the same sign-in holds")
    func cancelAndSignOutAnyway() async {
        let cancelled = FakeAccountKeyFlows()
        cancelled.fail("signOutKeys", with: FakeAccountKeyFlows.failure("sync.server"))
        #expect(await Self.signOut(cancelled, answers: [.cancel]).signOut { true } == false)

        let anyway = FakeAccountKeyFlows()
        anyway.fail("signOutKeys", with: FakeAccountKeyFlows.failure("sync.server"))
        #expect(await Self.signOut(anyway, answers: [.signOutAnyway]).signOut { true })

        let switched = FakeAccountKeyFlows()
        switched.fail("signOutKeys", with: FakeAccountKeyFlows.failure("sync.server"))
        var current = true
        let keys = AccountKeysSignOut.over({ switched }) { _ in
            current = false
            return .signOutAnyway
        }
        #expect(await keys.signOut { current } == false)
    }

    @Test("A service with no key engine has nothing to erase, so the sign-out goes on")
    func noKeyEngine() async {
        let flows = FakeAccountKeyFlows()
        flows.fail("signOutKeys", with: FakeAccountKeyFlows.failure("sync.unimplemented"))

        #expect(await Self.signOut(flows, answers: []).signOut { true })
    }

    @Test("Only an approved or locked device holds keys that Sign Out erases")
    func holdsKeys() async {
        let flows = FakeAccountKeyFlows()
        let keys = Self.signOut(flows, answers: [])

        flows.state = .approved(av: 1, keyDevice: "key-this")
        #expect(await keys.holdsKeys())
        flows.state = .locked(cause: .deviceRemoved)
        #expect(await keys.holdsKeys())
        flows.state = .needsApproval(request: nil)
        #expect(await keys.holdsKeys() == false)
    }

    @Test("The prompt answers the one question open, and a new question answers the old one Cancel")
    func promptAnswers() async throws {
        let prompt = AccountKeysSignOutPrompt()

        let first = Task { await prompt.ask("first") }
        try await waitUntil { prompt.reason == "first" }
        let second = Task { await prompt.ask("second") }
        try await waitUntil { prompt.reason == "second" }
        prompt.settle(.retry)

        #expect(await first.value == .cancel)
        #expect(await second.value == .retry)
        #expect(!prompt.isAsking)
    }
}
