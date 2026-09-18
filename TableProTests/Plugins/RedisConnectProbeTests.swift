import Foundation
import Testing

@Suite("Redis connect probe")
struct RedisConnectProbeTests {
    @Test("a reply with no error means the server bound the session")
    func successEstablishes() {
        #expect(RedisConnectProbe.outcome(errorMessage: nil) == .established)
        #expect(RedisConnectProbe.outcome(errorMessage: "") == .established)
    }

    @Test("NOAUTH is the only reply that means no identity")
    func noAuthIsFatal() {
        #expect(RedisConnectProbe.outcome(errorMessage: "NOAUTH Authentication required.") == .unauthenticated)
    }

    @Test("NOPERM means authenticated but restricted, which is a usable session")
    func noPermEstablishes() {
        let denied = "NOPERM User dave has no permissions to run the 'ping' command"
        #expect(RedisConnectProbe.outcome(errorMessage: denied) == .established)
    }

    @Test("any other error reply still fails the connection and carries the server text")
    func otherErrorsRefuse() {
        #expect(
            RedisConnectProbe.outcome(errorMessage: "LOADING dataset in memory")
                == .refused("LOADING dataset in memory")
        )
        #expect(RedisConnectProbe.outcome(errorMessage: "BUSY Redis is busy") == .refused("BUSY Redis is busy"))
    }

    @Test("the error class is matched whole, not as a prefix")
    func errorClassIsDelimited() {
        #expect(RedisConnectProbe.outcome(errorMessage: "NOAUTHZ something new") == .refused("NOAUTHZ something new"))
        #expect(RedisConnectProbe.outcome(errorMessage: "NOPERMISSION something new") != .established)
    }

    @Test("the error class is matched case-insensitively")
    func errorClassIsCaseInsensitive() {
        #expect(RedisConnectProbe.outcome(errorMessage: "noauth Authentication required.") == .unauthenticated)
    }

    @Test("only a failing outcome carries a message, and only the unauthenticated one names a field")
    func messagesMatchOutcomes() {
        #expect(RedisConnectProbe.Outcome.established.failureMessage == nil)
        #expect(RedisConnectProbe.Outcome.established.failureHint == nil)
        #expect(RedisConnectProbe.Outcome.unauthenticated.failureMessage?.isEmpty == false)
        #expect(RedisConnectProbe.Outcome.unauthenticated.failureHint?.isEmpty == false)

        let refused = RedisConnectProbe.Outcome.refused("LOADING dataset in memory")
        #expect(refused.failureMessage?.contains("LOADING dataset in memory") == true)
        #expect(refused.failureHint == nil)
    }

    @Test("the probe asks for PING")
    func probeCommand() {
        #expect(RedisConnectProbe.command == ["PING"])
    }
}
