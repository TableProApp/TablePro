import Foundation
import TableProGoogleCloud
import Testing

struct BigQueryRequestLoopTests {
    private final class Script {
        var statuses: [Int]
        var sent = 0
        var refreshed = 0
        var backoffs: [Int] = []
        let signal = BigQueryStopSignal()
        var stopWhileAuthorizing = false
        var stopDuringBackoff = false

        init(_ statuses: [Int]) {
            self.statuses = statuses
        }

        func run() async throws -> BigQueryRequestLoop.Answer? {
            try await BigQueryRequestLoop.run(
                isStopped: { signal.isStopped },
                authorize: {
                    if stopWhileAuthorizing { signal.stop() }
                    return "token"
                },
                send: { _ in
                    sent += 1
                    return BigQueryRequestLoop.Answer(status: statuses.removeFirst(), data: Data())
                },
                refreshToken: { refreshed += 1 },
                backoff: { attempt in
                    backoffs.append(attempt)
                    if stopDuringBackoff { signal.stop() }
                }
            )
        }
    }

    @Test("A request that succeeds is sent once")
    func successIsSentOnce() async throws {
        let script = Script([200])
        #expect(try await script.run()?.status == 200)
        #expect(script.sent == 1)
    }

    @Test("Stop before the first send sends nothing")
    func stopBeforeSendSendsNothing() async throws {
        let script = Script([200])
        script.signal.stop()

        #expect(try await script.run() == nil)
        #expect(script.sent == 0)
    }

    @Test("Stop while the token is fetched sends nothing")
    func stopWhileAuthorizingSendsNothing() async throws {
        let script = Script([200])
        script.stopWhileAuthorizing = true

        #expect(try await script.run() == nil)
        #expect(script.sent == 0)
    }

    @Test("Stop during a rate limit backoff sends no second request")
    func stopDuringBackoffSendsNoRetry() async throws {
        let script = Script([429, 200])
        script.stopDuringBackoff = true

        #expect(try await script.run() == nil)
        #expect(script.sent == 1)
    }

    @Test("A rate limit is waited out with a longer wait each time")
    func rateLimitRetries() async throws {
        let script = Script([429, 429, 200])

        #expect(try await script.run()?.status == 200)
        #expect(script.backoffs == [1, 2])
    }

    @Test("A rate limit that never lifts comes back to the caller")
    func rateLimitGivesUp() async throws {
        let script = Script([429, 429, 429, 429])

        #expect(try await script.run()?.status == 429)
        #expect(script.sent == 4)
    }

    @Test("An expired token is refreshed once")
    func refreshesTheTokenOnce() async throws {
        let script = Script([401, 401])

        #expect(try await script.run()?.status == 401)
        #expect(script.refreshed == 1)
        #expect(script.sent == 2)
    }

    @Test("Any other answer comes back as it is", arguments: [400, 403, 404, 500])
    func otherStatusesReturn(status: Int) async throws {
        let script = Script([status])

        #expect(try await script.run()?.status == status)
        #expect(script.sent == 1)
    }
}
