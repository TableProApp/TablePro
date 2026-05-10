import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("MCP Rate Limiter")
struct MCPRateLimiterNewTests {
    private func standardKey() -> MCPRateLimitKey {
        MCPRateLimitKey(clientAddress: .loopback, principalFingerprint: "abcd1234")
    }

    @Test("Five failures lock the key")
    func fiveFailuresLock() async {
        let clock = MCPTestClock()
        let limiter = MCPRateLimiter(clock: clock)
        let key = standardKey()

        for _ in 0..<4 {
            let verdict = await limiter.recordAttempt(key: key, success: false)
            #expect(verdict == .allowed)
        }
        let final = await limiter.recordAttempt(key: key, success: false)
        guard case .lockedUntil = final else {
            Issue.record("Expected lockedUntil, got \(final)")
            return
        }
        let locked = await limiter.isLocked(key: key)
        #expect(locked == true)
    }

    @Test("Lock expires after lockout duration")
    func lockExpires() async {
        let clock = MCPTestClock()
        let limiter = MCPRateLimiter(
            policy: MCPRateLimitPolicy(
                maxFailedAttempts: 3,
                windowDuration: .seconds(60),
                lockoutDuration: .seconds(120)
            ),
            clock: clock
        )
        let key = standardKey()

        for _ in 0..<3 {
            _ = await limiter.recordAttempt(key: key, success: false)
        }
        let lockedNow = await limiter.isLocked(key: key)
        #expect(lockedNow == true)

        await clock.advance(by: .seconds(121))
        let lockedLater = await limiter.isLocked(key: key)
        #expect(lockedLater == false)
    }

    @Test("Different keys are isolated")
    func differentKeysIsolated() async {
        let clock = MCPTestClock()
        let limiter = MCPRateLimiter(clock: clock)
        let keyA = MCPRateLimitKey(clientAddress: .loopback, principalFingerprint: "tokenA")
        let keyB = MCPRateLimitKey(clientAddress: .loopback, principalFingerprint: "tokenB")

        for _ in 0..<5 {
            _ = await limiter.recordAttempt(key: keyA, success: false)
        }
        let lockedA = await limiter.isLocked(key: keyA)
        let lockedB = await limiter.isLocked(key: keyB)
        #expect(lockedA == true)
        #expect(lockedB == false)
    }

    @Test("Same address different principal does not share bucket")
    func sameAddressDifferentPrincipal() async {
        let clock = MCPTestClock()
        let limiter = MCPRateLimiter(clock: clock)
        let attacker = MCPRateLimitKey(clientAddress: .loopback, principalFingerprint: "bad")
        let legitimate = MCPRateLimitKey(clientAddress: .loopback, principalFingerprint: "good")

        for _ in 0..<5 {
            _ = await limiter.recordAttempt(key: attacker, success: false)
        }
        let allowed = await limiter.recordAttempt(key: legitimate, success: true)
        #expect(allowed == .allowed)
    }

    @Test("Success resets failure count")
    func successResetsFailureCount() async {
        let clock = MCPTestClock()
        let limiter = MCPRateLimiter(
            policy: MCPRateLimitPolicy(
                maxFailedAttempts: 5,
                windowDuration: .seconds(60),
                lockoutDuration: .seconds(300)
            ),
            clock: clock
        )
        let key = standardKey()

        for _ in 0..<3 {
            _ = await limiter.recordAttempt(key: key, success: false)
        }
        _ = await limiter.recordAttempt(key: key, success: true)

        for _ in 0..<4 {
            let verdict = await limiter.recordAttempt(key: key, success: false)
            #expect(verdict == .allowed)
        }
        let locked = await limiter.isLocked(key: key)
        #expect(locked == false)
    }

    @Test("Failures outside window do not count")
    func failuresOutsideWindowExpire() async {
        let clock = MCPTestClock()
        let limiter = MCPRateLimiter(
            policy: MCPRateLimitPolicy(
                maxFailedAttempts: 5,
                windowDuration: .seconds(60),
                lockoutDuration: .seconds(300)
            ),
            clock: clock
        )
        let key = standardKey()

        for _ in 0..<4 {
            _ = await limiter.recordAttempt(key: key, success: false)
        }
        await clock.advance(by: .seconds(120))
        let verdict = await limiter.recordAttempt(key: key, success: false)
        #expect(verdict == .allowed)
    }

    @Test("Reset clears the bucket")
    func resetClearsBucket() async {
        let clock = MCPTestClock()
        let limiter = MCPRateLimiter(clock: clock)
        let key = standardKey()
        for _ in 0..<5 {
            _ = await limiter.recordAttempt(key: key, success: false)
        }
        await limiter.reset(key: key)
        let locked = await limiter.isLocked(key: key)
        #expect(locked == false)
    }
}
