import Foundation
import os
@testable import TableProMobile
import TableProTestSupport
import Testing

struct MySQLKillSignInTests {
    @Test("A young session token serves every kill without a mint")
    func youngTokenIsReused() async {
        let clock = ManualClock()
        let mints = OSAllocatedUnfairLock(initialState: 0)
        let signIn = MySQLKillSignIn(
            password: "connect-token",
            refresh: { mints.withLock { $0 += 1 }; return "fresh-token" },
            clock: clock
        )

        clock.advance(by: .seconds(599))
        let first = await Self.credential(signIn)
        let second = await Self.credential(signIn)
        let minted = mints.withLock { $0 }

        #expect(first == MySQLKillSignIn.Credential(password: "connect-token", isReused: true))
        #expect(second == first)
        #expect(minted == 0)
    }

    @Test("A reused token the server refuses is replaced by one mint, which later kills reuse")
    func refusedTokenIsMintedOnce() async {
        let clock = ManualClock()
        let mints = OSAllocatedUnfairLock(initialState: 0)
        let signIn = MySQLKillSignIn(
            password: "connect-token",
            refresh: { "fresh-\(mints.withLock { $0 += 1; return $0 })" },
            clock: clock
        )

        let refused = await Self.credential(signIn)
        let replacement = await Self.afterRefusal(of: refused.password, signIn)
        let staleRefusal = await Self.afterRefusal(of: refused.password, signIn)
        let next = await Self.credential(signIn)

        #expect(replacement == "fresh-1")
        #expect(staleRefusal == "fresh-1")
        #expect(next == MySQLKillSignIn.Credential(password: "fresh-1", isReused: true))
    }

    @Test("A refused token with a mint that fails leaves the kill nothing to try again")
    func refusalWithFailedMint() async {
        let signIn = MySQLKillSignIn(
            password: "connect-token", refresh: { throw MintFailure() }, clock: ManualClock()
        )

        let replacement = await Self.afterRefusal(of: "connect-token", signIn)

        #expect(replacement == nil)
    }

    private struct MintFailure: Error {}

    @Test("Past ten minutes a kill mints once, and later kills reuse that token for ten more")
    func oldTokenIsMintedOnceThenReused() async {
        let clock = ManualClock()
        let mints = OSAllocatedUnfairLock(initialState: 0)
        let signIn = MySQLKillSignIn(
            password: "connect-token",
            refresh: { "fresh-\(mints.withLock { $0 += 1; return $0 })" },
            clock: clock
        )

        clock.advance(by: .seconds(600))
        let pastWindow = await Self.credential(signIn)
        clock.advance(by: .seconds(300))
        let reused = await Self.credential(signIn)
        clock.advance(by: .seconds(300))
        let mintedAgain = await Self.credential(signIn)

        #expect(pastWindow == MySQLKillSignIn.Credential(password: "fresh-1", isReused: false))
        #expect(reused == MySQLKillSignIn.Credential(password: "fresh-1", isReused: true))
        #expect(mintedAgain == MySQLKillSignIn.Credential(password: "fresh-2", isReused: false))
    }

    @Test("A mint that yields nothing keeps the session token, and the next kill tries again")
    func emptyMintRetries() async {
        let clock = ManualClock()
        let mints = OSAllocatedUnfairLock(initialState: 0)
        let signIn = MySQLKillSignIn(
            password: "connect-token",
            refresh: { mints.withLock { $0 += 1; return $0 } == 1 ? nil : "fresh-token" },
            clock: clock
        )

        clock.advance(by: .seconds(601))
        let afterEmpty = await Self.credential(signIn)
        let afterRetry = await Self.credential(signIn)

        #expect(afterEmpty == MySQLKillSignIn.Credential(password: "connect-token", isReused: false))
        #expect(afterRetry.password == "fresh-token")
    }

    @Test("A password session signs every kill in with its password")
    func passwordSessionNeverMints() async {
        let clock = ManualClock()
        let signIn = MySQLKillSignIn(password: "app-password", refresh: nil, clock: clock)

        clock.advance(by: .seconds(3_600))
        let credential = await Self.credential(signIn)

        #expect(credential == MySQLKillSignIn.Credential(password: "app-password", isReused: false))
    }

    // Off the Swift concurrency threads, as the kill queue calls them.
    private static func credential(_ signIn: MySQLKillSignIn) async -> MySQLKillSignIn.Credential {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: signIn.credential()) }
        }
    }

    private static func afterRefusal(of password: String, _ signIn: MySQLKillSignIn) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: signIn.passwordAfterRefusal(of: password)) }
        }
    }
}
