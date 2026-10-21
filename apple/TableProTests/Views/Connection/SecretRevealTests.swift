import Foundation
@testable import TablePro
import Testing

@MainActor
struct SecretRevealTests {
    @Test("A saved password stays hidden when authentication is refused")
    func refusedAuthenticationKeepsItHidden() async {
        let authenticator = StubAuthenticating(answer: false)
        let reveal = SecretReveal(authenticator: authenticator)

        await reveal.setRevealed(true, requiresAuthentication: true)

        #expect(!reveal.isRevealed)
        #expect(authenticator.callCount == 1)
        #expect(authenticator.lastReason == SecretReveal.authenticationReason)
    }

    @Test("A saved password shows after authenticating, and asks only once")
    func authenticatesOnce() async {
        let authenticator = StubAuthenticating(answer: true)
        let reveal = SecretReveal(authenticator: authenticator)

        await reveal.setRevealed(true, requiresAuthentication: true)
        #expect(reveal.isRevealed)

        await reveal.setRevealed(false, requiresAuthentication: true)
        #expect(!reveal.isRevealed)

        await reveal.setRevealed(true, requiresAuthentication: true)
        #expect(reveal.isRevealed)
        #expect(authenticator.callCount == 1)
    }

    @Test("A password typed in this window shows without authenticating")
    func typedPasswordNeedsNoAuthentication() async {
        let authenticator = StubAuthenticating(answer: false)
        let reveal = SecretReveal(authenticator: authenticator)

        await reveal.setRevealed(true, requiresAuthentication: false)

        #expect(reveal.isRevealed)
        #expect(authenticator.callCount == 0)
    }
}
