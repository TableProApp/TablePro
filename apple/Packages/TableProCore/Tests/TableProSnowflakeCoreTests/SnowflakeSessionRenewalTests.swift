import Foundation
import TableProSnowflakeCore
import Testing

struct SnowflakeSessionRenewalTests {
    private final class Session {
        var token: String? = "t1"
        var renewals = 0
        var sent: [String] = []
    }

    private func send(
        _ session: Session,
        expiredTokens: Set<String>,
        beforeRenewalCheck: () -> Void = {}
    ) async throws -> (response: String, token: String)? {
        try await SnowflakeSessionRenewal.send(
            currentToken: { session.token },
            isExpired: { (response: String) in response == "expired" },
            renew: { expired in
                guard session.token == expired else { return }
                session.renewals += 1
                session.token = "t\(session.renewals + 1)"
            },
            request: { token in
                session.sent.append("poll /queries/q1/result as \(token)")
                guard expiredTokens.contains(token) else { return "done" }
                beforeRenewalCheck()
                return "expired"
            }
        )
    }

    @Test("A request the server accepts is sent once and nothing is renewed")
    func acceptedRequest() async throws {
        let session = Session()
        let sent = try await send(session, expiredTokens: [])
        #expect(sent?.response == "done")
        #expect(sent?.token == "t1")
        #expect(session.renewals == 0)
        #expect(session.sent.count == 1)
    }

    @Test("An expired token is renewed and the same request goes out again with the new token")
    func expiredTokenResendsTheSameRequest() async throws {
        let session = Session()
        let sent = try await send(session, expiredTokens: ["t1"])
        #expect(sent?.response == "done")
        #expect(sent?.token == "t2")
        #expect(session.renewals == 1)
        #expect(session.sent == ["poll /queries/q1/result as t1", "poll /queries/q1/result as t2"])
    }

    @Test("A token another request already renewed is not renewed a second time")
    func alreadyRenewedTokenIsReused() async throws {
        let session = Session()
        let sent = try await send(session, expiredTokens: ["t1"]) { session.token = "other" }
        #expect(sent?.token == "other")
        #expect(session.renewals == 0)
    }

    @Test("A token that is still refused after renewal returns the refusal, without a third attempt")
    func stillExpiredAfterRenewal() async throws {
        let session = Session()
        let sent = try await send(session, expiredTokens: ["t1", "t2"])
        #expect(sent?.response == "expired")
        #expect(session.renewals == 1)
        #expect(session.sent.count == 2)
    }

    @Test("No session token sends nothing")
    func missingToken() async throws {
        let session = Session()
        session.token = nil
        #expect(try await send(session, expiredTokens: []) == nil)
        #expect(session.sent.isEmpty)
    }

    @Test("A failed renewal surfaces and the request is not sent again")
    func failedRenewal() async {
        struct RenewalFailed: Error {}
        let session = Session()
        await #expect(throws: RenewalFailed.self) {
            _ = try await SnowflakeSessionRenewal.send(
                currentToken: { "t1" },
                isExpired: { (_: String) in true },
                renew: { _ in throw RenewalFailed() },
                request: { token in
                    session.sent.append(token)
                    return "expired"
                }
            )
        }
        #expect(session.sent == ["t1"])
    }
}
