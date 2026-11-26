//
//  StepUpRetryTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProFFI
import Testing

@MainActor
struct StepUpRetryTests {
    private static func failure(
        _ code: String,
        sync: SyncFailureInfo? = nil,
        stepUp: StepUpChallengeInfo? = nil
    ) -> CoreError {
        .Failed(info: ErrorInfo(
            code: code,
            codes: [code],
            message: "",
            server: nil,
            path: nil,
            secret: nil,
            hostKey: nil,
            tlsFailure: nil,
            ai: nil,
            sync: sync,
            stepUp: stepUp
        ))
    }

    private static let passkey = ["urn:tablepro:acr:passkey", "urn:tablepro:acr:email-code"]

    private final class Calls {
        var made = 0
        var stepUps: [StepUpChallenge] = []
    }

    @Test("A key flow's challenge steps up with its values, then the call runs once more")
    func stepsUpAndRetries() async throws {
        let calls = Calls()
        let retry = StepUpRetry { calls.stepUps.append($0) }

        let value = try await retry.run { () throws -> String in
            calls.made += 1
            if calls.made == 1 {
                throw Self.failure("sync.step_up_required", sync: .stepUp(acrValues: Self.passkey, maxAgeSecs: 300))
            }
            return "removed"
        }

        #expect(value == "removed")
        #expect(calls.made == 2)
        #expect(calls.stepUps == [StepUpChallenge(acrValues: Self.passkey, maxAgeSecs: 300)])
    }

    @Test("The account's own challenge is read from the error too")
    func readsTheAccountChallenge() {
        let error = Self.failure(
            "account.step_up_required",
            stepUp: StepUpChallengeInfo(acrValues: Self.passkey, maxAgeSecs: nil)
        )

        #expect(StepUpChallenge(error) == StepUpChallenge(acrValues: Self.passkey, maxAgeSecs: nil))
        #expect(StepUpChallenge(Self.failure("sync.device_removed")) == nil)
        #expect(StepUpChallenge(CoreError.Cancelled) == nil)
    }

    @Test("A second challenge goes to the caller after one step-up")
    func secondChallengeIsThrown() async {
        let calls = Calls()
        let retry = StepUpRetry { calls.stepUps.append($0) }
        let challenged = Self.failure("sync.step_up_required", sync: .stepUp(acrValues: Self.passkey, maxAgeSecs: 300))

        await #expect(throws: CoreError.self) {
            try await retry.run { () throws -> Void in
                calls.made += 1
                throw challenged
            }
        }

        #expect(calls.made == 2)
        #expect(calls.stepUps.count == 1)
        #expect(StepUpRetry.failure(challenged) != nil)
    }

    @Test("Another error is thrown as it came, with no step-up")
    func otherErrorsPassThrough() async {
        let calls = Calls()
        let retry = StepUpRetry { calls.stepUps.append($0) }

        await #expect(throws: CoreError.self) {
            try await retry.run { () throws -> Void in
                calls.made += 1
                throw Self.failure("sync.device_not_approved")
            }
        }

        #expect(calls.made == 1)
        #expect(calls.stepUps.isEmpty)
        #expect(StepUpRetry.failure(Self.failure("sync.device_not_approved")) == nil)
    }

    @Test("A step-up the person closed stops the call and says nothing")
    func canceledStepUp() async {
        let calls = Calls()
        let retry = StepUpRetry { _ in throw AccountError.canceled }

        await #expect(throws: AccountError.canceled) {
            try await retry.run { () throws -> Void in
                calls.made += 1
                throw Self.failure("sync.step_up_required", sync: .stepUp(acrValues: Self.passkey, maxAgeSecs: 300))
            }
        }

        #expect(calls.made == 1)
        #expect(StepUpRetry.failure(AccountError.canceled) == .canceled)
        let otherAccount = StepUpRetry.failure(AccountError.server(status: 403, code: "step_up_other_account"))
        #expect(otherAccount != nil && otherAccount != .canceled)
    }

    @Test("The account steps up on the sign-in page with the challenge's methods and stays signed in")
    func accountStepsUp() async throws {
        let fixture = try AccountFixture()
        try await fixture.signIn()

        try await fixture.services.stepUp(
            acrValues: Self.passkey,
            maxAgeSecs: 300,
            using: FakeAuthenticator(server: fixture.server)
        )

        #expect(fixture.backend.stepUpChallenges == [Self.passkey])
        #expect(fixture.services.isSignedIn)
    }

    @Test("The core's step-up codes map to server codes the app words")
    func mapsStepUpCodes() {
        #expect(CoreAccountMapping.error(Self.failure("account.step_up_required"), during: .other)
            == .server(status: 401, code: "step_up_required"))
        #expect(CoreAccountMapping.error(Self.failure("account.step_up_other_account"), during: .other)
            == .server(status: 403, code: "step_up_other_account"))
    }
}
