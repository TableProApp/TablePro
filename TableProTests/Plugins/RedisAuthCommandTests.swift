import Foundation
import Testing

@Suite("Redis AUTH command")
struct RedisAuthCommandTests {
    @Test("no credentials at all sends no AUTH")
    func noCredentials() {
        #expect(RedisAuthCommand.arguments(username: nil, password: nil) == nil)
        #expect(RedisAuthCommand.arguments(username: nil, password: "") == nil)
        #expect(RedisAuthCommand.arguments(username: "", password: "") == nil)
    }

    @Test("a username with no password still authenticates as that user")
    func usernameWithoutPassword() {
        #expect(RedisAuthCommand.arguments(username: "acl-user", password: nil) == ["AUTH", "acl-user", ""])
        #expect(RedisAuthCommand.arguments(username: "acl-user", password: "") == ["AUTH", "acl-user", ""])
    }

    @Test("password without a username uses the one-argument form")
    func passwordOnly() {
        #expect(RedisAuthCommand.arguments(username: nil, password: "s3cret") == ["AUTH", "s3cret"])
        #expect(RedisAuthCommand.arguments(username: "", password: "s3cret") == ["AUTH", "s3cret"])
    }

    @Test("a username sends the ACL form so the server does not fall back to the default user")
    func usernameAndPassword() {
        #expect(
            RedisAuthCommand.arguments(username: "acl-user", password: "s3cret")
                == ["AUTH", "acl-user", "s3cret"]
        )
    }

    @Test("a 64-character hex password is passed through unchanged")
    func generatedPasswordSurvivesIntact() {
        let password = String(repeating: "a1b2c3d4", count: 8)
        #expect(password.count == 64)
        #expect(
            RedisAuthCommand.arguments(username: "acl-user", password: password)
                == ["AUTH", "acl-user", password]
        )
    }

    @Test("WRONGPASS without a username points at the missing ACL username")
    func wrongPassWithoutUsername() {
        let serverError = "WRONGPASS invalid username-password pair or user is disabled."
        #expect(
            RedisAuthCommand.failure(serverError: serverError, hadUsername: false, hadPassword: true)
                == .rejectedWithoutUsername
        )
    }

    @Test("WRONGPASS for a username sent with no password points at the empty Password field")
    func wrongPassWithoutPassword() {
        let serverError = "WRONGPASS invalid username-password pair or user is disabled."
        #expect(
            RedisAuthCommand.failure(serverError: serverError, hadUsername: true, hadPassword: false)
                == .rejectedWithoutPassword
        )
    }

    @Test("WRONGPASS with both fields filled stays an ordinary credential rejection")
    func wrongPassWithUsername() {
        let serverError = "WRONGPASS invalid username-password pair or user is disabled."
        #expect(
            RedisAuthCommand.failure(serverError: serverError, hadUsername: true, hadPassword: true)
                == .rejectedCredentials
        )
    }

    @Test("a server with no password configured is reported as such")
    func serverHasNoPassword() {
        let modern = "ERR AUTH <password> called without any password configured for the default user."
        #expect(
            RedisAuthCommand.failure(serverError: modern, hadUsername: false, hadPassword: true)
                == .serverHasNoPassword
        )

        let legacy = "ERR Client sent AUTH, but no password is set"
        #expect(
            RedisAuthCommand.failure(serverError: legacy, hadUsername: false, hadPassword: true)
                == .serverHasNoPassword
        )
    }

    @Test("a pre-ACL server's wrong-password reply never suggests an ACL username")
    func legacyInvalidPasswordCarriesNoUsernameHint() {
        let serverError = "ERR invalid password"
        #expect(
            RedisAuthCommand.failure(serverError: serverError, hadUsername: false, hadPassword: true)
                == .rejectedCredentials
        )
        #expect(
            RedisAuthCommand.failure(serverError: serverError, hadUsername: true, hadPassword: true)
                == .rejectedCredentials
        )
    }

    @Test("a pre-ACL server rejects the username form with an arity error")
    func usernameUnsupported() {
        let serverError = "ERR wrong number of arguments for 'auth' command"
        #expect(
            RedisAuthCommand.failure(serverError: serverError, hadUsername: true, hadPassword: false)
                == .usernameUnsupported
        )
    }

    @Test("an unrelated error carries no hint")
    func unrecognized() {
        #expect(
            RedisAuthCommand.failure(serverError: "LOADING dataset in memory", hadUsername: true, hadPassword: true)
                == .unrecognized
        )
        #expect(RedisAuthCommand.hint(for: .unrecognized) == nil)
        #expect(RedisAuthCommand.hint(for: .rejectedCredentials) == nil)
    }

    @Test("every actionable failure names the field to change")
    func actionableFailuresCarryAHint() {
        let actionable: [RedisAuthCommand.Failure] = [
            .rejectedWithoutUsername,
            .rejectedWithoutPassword,
            .serverHasNoPassword,
            .usernameUnsupported,
        ]
        for failure in actionable {
            #expect(RedisAuthCommand.hint(for: failure)?.isEmpty == false)
        }
    }
}
