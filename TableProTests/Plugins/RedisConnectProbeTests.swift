import Foundation
import Testing

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

struct RedisConnectTimeoutTests {
    private func pluginSource(_ name: String) throws -> String {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repository
                .appendingPathComponent("Plugins/RedisDriverPlugin")
                .appendingPathComponent(name),
            encoding: .utf8
        )
    }

    @Test("The remaining millisecond budget becomes hiredis wall time")
    func hiredisBudget() {
        let timeout = RedisConnectTimeout(additionalFields: ["connectTimeoutMilliseconds": "2750"])

        #expect(timeout.milliseconds == 2_750)
        #expect(timeout.timeInterval == 2.75)
    }

    @Test("One deadline shrinks across Redis connection phases")
    func deadlineShrinks() {
        let deadline = RedisConnectDeadline(timeout: RedisConnectTimeout(milliseconds: 2_750), now: 100)

        #expect(deadline.remainingMilliseconds(now: 101.25) == 1_500)
        #expect(deadline.socketTimeout(now: 101.5) == RedisSocketTimeout(seconds: 1, microseconds: 250_000))
        #expect(deadline.remainingMilliseconds(now: 102.75) == nil)
        #expect(deadline.socketTimeout(now: 102.75) == nil)
    }

    @Test("The compatibility seconds value is checked and clamped")
    func secondsFallbackClamps() {
        #expect(RedisConnectTimeout(additionalFields: ["connectTimeoutSeconds": "8"]).milliseconds == 8_000)
        #expect(RedisConnectTimeout(additionalFields: ["connectTimeoutSeconds": "0"]).milliseconds == 1)
        #expect(RedisConnectTimeout(additionalFields: ["connectTimeoutSeconds": String(Int64.min)]).milliseconds == 1)
        #expect(
            RedisConnectTimeout(additionalFields: ["connectTimeoutMilliseconds": "999999999"]).milliseconds
                == RedisConnectTimeout.maximumMilliseconds
        )
    }

    @Test("INFO probes run before the Redis session timeout replaces the connect deadline")
    func bootstrapLifecycleOrder() throws {
        let connection = try pluginSource("RedisPluginConnection.swift")
        let driver = try pluginSource("RedisPluginDriver.swift")

        #expect(connection.contains("if let deadline = activeConnectDeadline"))
        #expect(connection.contains("armConnectWatchdog(deadline: deadline)"))
        #expect(connection.contains("Darwin.shutdown(context.pointee.fd, SHUT_RDWR)"))
        #expect(connection.components(separatedBy: "timeval(tv_sec: 30, tv_usec: 0)").count == 2)
        let modeProbe = try #require(driver.range(of: "try await verifyServerMode(mode, on: channel)"))
        let adoption = try #require(driver.range(of: "try await channel.finishConnecting()"))
        #expect(modeProbe.lowerBound < adoption.lowerBound)
    }
}
