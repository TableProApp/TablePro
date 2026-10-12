import Foundation
@testable import TableProMobile
import TableProModels
import Testing

private struct DescribedError: LocalizedError {
    let errorDescription: String?
}

@Suite("Redis error classification")
struct RedisErrorClassifierTests {
    private func classify(_ error: Error, databaseType: DatabaseType = .redis) -> AppError {
        ErrorClassifier.classify(
            error,
            context: ErrorContext(operation: "executeQuery", databaseType: databaseType, host: "cache.example.com")
        )
    }

    @Test("an ACL refusal is a permission error, not a failed sign-in", arguments: [
        "NOPERM User limited has no permissions to run the 'get' command",
        "NOPERM No permissions to access a key"
    ])
    func noPermIsPermissionDenied(reply: String) {
        let error = classify(RedisError.queryFailed(reply))
        #expect(error.category == .permission)
        #expect(error.title == String(localized: "Permission Denied"))
        #expect(error.recovery == String(
            localized: "This connection's Redis user is not allowed to run this command or reach this key. Ask an administrator to grant it in the user's ACL."
        ))
        #expect(error.message.contains(reply))
    }

    @Test("a rejected sign-in stays an authentication failure", arguments: [
        RedisError.authenticationFailed(
            serverMessage: "WRONGPASS invalid username-password pair or user is disabled.",
            failure: .rejectedCredentials
        ),
        .queryFailed("WRONGPASS invalid username-password pair or user is disabled."),
        .queryFailed("NOAUTH Authentication required."),
        .sessionUnverified(.unauthenticated)
    ])
    func authRepliesStayAuth(error: RedisError) {
        let classified = classify(error)
        #expect(classified.category == .auth)
        #expect(classified.title == String(localized: "Authentication Failed"))
    }

    @Test("words the server echoes from the command do not decide the category", arguments: [
        "ERR unknown command 'FOO', with args beginning with: 'password' ",
        "ERR unknown command 'FOO', with args beginning with: 'ssh-keys' ",
        "ERR unknown command 'DELETE', with args beginning with: 'FROM' 'user:1' "
    ])
    func echoedWordsAreNotRead(reply: String) {
        let error = classify(RedisError.queryFailed(reply))
        #expect(error.category == .query)
        #expect(error.title == String(localized: "Query Error"))
        #expect(error.recovery == nil)
    }

    @Test("a server that refuses the probe for another reason is a query error")
    func refusedProbeIsQuery() {
        let error = classify(RedisError.sessionUnverified(.refused("LOADING Redis is loading the dataset in memory")))
        #expect(error.category == .query)
    }

    @Test("a queued command is a query error that carries its own hint")
    func queuedCommandIsQuery() {
        let error = classify(RedisError.commandQueued("TYPE"))
        #expect(error.category == .query)
        #expect(error.recovery == nil)
        #expect(error.message == RedisError.commandQueued("TYPE").localizedDescription)
    }

    @Test("a closed handle asks for a reconnect")
    func notConnected() {
        let error = classify(RedisError.notConnected)
        #expect(error.category == .system)
        #expect(error.title == String(localized: "Not Connected"))
        #expect(error.recovery == String(localized: "Reconnect and try again."))
    }

    @Test("a key that is gone points back to the key list")
    func keyNotFound() {
        let error = classify(RedisError.keyNotFound("session:42"))
        #expect(error.category == .query)
        #expect(error.title == String(localized: "Key Not Found"))
        #expect(error.recovery == String(localized: "Pull down on the key list to refresh it."))
        #expect(error.message == String(format: String(localized: "The key %@ no longer exists."), "session:42"))
    }

    @Test("a key type the browser cannot open points to Query")
    func keyTypeNotBrowsable() {
        let error = classify(RedisError.keyTypeNotBrowsable("vectorset"))
        #expect(error.category == .config)
        #expect(error.title == String(localized: "Unsupported Key Type"))
        #expect(error.recovery == String(localized: "Read it with a command in Query."))
    }

    @Test("a refused connection is still a network failure")
    func connectionRefusedIsNetwork() {
        let error = classify(RedisError.connectionFailed("Connection refused"))
        #expect(error.category == .network)
    }

    @Test("a connection the server drops mid-command is still a network failure")
    func connectionResetIsNetwork() {
        let error = classify(RedisError.connectionFailed("Connection reset by peer"))
        #expect(error.category == .network)
    }

    @Test("other engines' sign-in failures keep their classification")
    func otherEnginesStayAuth() {
        let cases: [(message: String, databaseType: DatabaseType)] = [
            (#"password authentication failed for user "app""#, .postgresql),
            ("Access denied for user 'root'@'localhost' (using password: YES)", .mysql)
        ]
        for testCase in cases {
            let error = classify(DescribedError(errorDescription: testCase.message), databaseType: testCase.databaseType)
            #expect(error.category == .auth, "\(testCase.message)")
            #expect(error.title == String(localized: "Authentication Failed"), "\(testCase.message)")
        }
    }
}
