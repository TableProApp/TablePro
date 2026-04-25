//
//  MCPRateLimiterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("MCP Rate Limiter")
struct MCPRateLimiterTests {
    // MARK: - Helpers

    private func makeLimiter() -> MCPRateLimiter {
        MCPRateLimiter()
    }

    private func expectAllowed(_ result: MCPRateLimiter.AuthRateResult, message: String = "") {
        guard case .allowed = result else {
            Issue.record("Expected .allowed but got \(result). \(message)")
            return
        }
    }

    @discardableResult
    private func expectRateLimited(_ result: MCPRateLimiter.AuthRateResult, message: String = "") -> Duration? {
        guard case .rateLimited(let retryAfter) = result else {
            Issue.record("Expected .rateLimited but got \(result). \(message)")
            return nil
        }
        return retryAfter
    }

    // MARK: - Basic Behavior

    @Test("First request is allowed")
    func firstRequestAllowed() async {
        let limiter = makeLimiter()
        let result = await limiter.checkAndRecord(ip: "1.2.3.4", success: false)
        expectAllowed(result)
    }

    @Test("Success clears failure record")
    func successClearsFailureRecord() async {
        let limiter = makeLimiter()
        _ = await limiter.checkAndRecord(ip: "1.2.3.4", success: false)
        _ = await limiter.checkAndRecord(ip: "1.2.3.4", success: true)
        let result = await limiter.checkAndRecord(ip: "1.2.3.4", success: false)
        expectAllowed(result, message: "Counter should have been reset by success")
    }

    @Test("Unknown IP is allowed")
    func unknownIpAllowed() async {
        let limiter = makeLimiter()
        let result = await limiter.checkAndRecord(ip: "never-seen-before", success: false)
        expectAllowed(result)
    }

    @Test("isLockedOut for unknown IP returns allowed")
    func isLockedOutUnknownIp() async {
        let limiter = makeLimiter()
        let result = await limiter.isLockedOut(ip: "unknown")
        expectAllowed(result)
    }

    // MARK: - Escalating Lockout

    @Test("Second failure triggers 1s lockout")
    func secondFailureLockout() async {
        let limiter = makeLimiter()
        _ = await limiter.checkAndRecord(ip: "10.0.0.1", success: false)
        let result = await limiter.checkAndRecord(ip: "10.0.0.1", success: false)

        guard let retryAfter = expectRateLimited(result, message: "Second failure should lock out") else { return }
        let seconds = retryAfter.components.seconds
        #expect(seconds >= 0 && seconds <= 2)
    }

    @Test("Third failure triggers 5s lockout after previous lockout expires")
    func thirdFailureLockout() async {
        let limiter = makeLimiter()
        _ = await limiter.checkAndRecord(ip: "10.0.0.2", success: false)
        _ = await limiter.checkAndRecord(ip: "10.0.0.2", success: false)

        try? await Task.sleep(for: .seconds(1.1))

        let result = await limiter.checkAndRecord(ip: "10.0.0.2", success: false)
        guard let retryAfter = expectRateLimited(result, message: "Third failure should lock out for ~5s") else { return }
        let seconds = retryAfter.components.seconds
        #expect(seconds >= 4 && seconds <= 6)
    }

    @Test("Fourth failure triggers 30s lockout")
    func fourthFailureLockout() async {
        let limiter = makeLimiter()
        _ = await limiter.checkAndRecord(ip: "10.0.0.3", success: false)
        _ = await limiter.checkAndRecord(ip: "10.0.0.3", success: false)

        try? await Task.sleep(for: .seconds(1.1))
        _ = await limiter.checkAndRecord(ip: "10.0.0.3", success: false)

        try? await Task.sleep(for: .seconds(5.1))
        let result = await limiter.checkAndRecord(ip: "10.0.0.3", success: false)

        guard let retryAfter = expectRateLimited(result, message: "Fourth failure should lock out for ~30s") else { return }
        let seconds = retryAfter.components.seconds
        #expect(seconds >= 28 && seconds <= 32)
    }

    @Test("Repeated failures while locked return remaining lockout time")
    func repeatedFailuresWhileLocked() async {
        let limiter = makeLimiter()
        _ = await limiter.checkAndRecord(ip: "10.0.0.4", success: false)
        let lockResult = await limiter.checkAndRecord(ip: "10.0.0.4", success: false)

        guard let initialRetry = expectRateLimited(lockResult) else { return }

        let retryResult = await limiter.checkAndRecord(ip: "10.0.0.4", success: false)
        guard let remainingRetry = expectRateLimited(retryResult, message: "Should still be locked") else { return }

        #expect(remainingRetry <= initialRetry)
    }

    // MARK: - Lockout Check

    @Test("isLockedOut returns rateLimited during lockout")
    func isLockedOutDuringLockout() async {
        let limiter = makeLimiter()
        _ = await limiter.checkAndRecord(ip: "10.0.1.1", success: false)
        _ = await limiter.checkAndRecord(ip: "10.0.1.1", success: false)

        let result = await limiter.isLockedOut(ip: "10.0.1.1")
        expectRateLimited(result, message: "Should be locked out after 2 failures")
    }

    @Test("isLockedOut returns allowed when not locked")
    func isLockedOutWhenNotLocked() async {
        let limiter = makeLimiter()
        let result = await limiter.isLockedOut(ip: "fresh-ip")
        expectAllowed(result)
    }

    // MARK: - Per-IP Isolation

    @Test("Different IPs have independent counters")
    func independentCounters() async {
        let limiter = makeLimiter()
        _ = await limiter.checkAndRecord(ip: "ip-a", success: false)
        _ = await limiter.checkAndRecord(ip: "ip-a", success: false)

        let lockedResult = await limiter.isLockedOut(ip: "ip-a")
        expectRateLimited(lockedResult, message: "IP-A should be locked")

        let resultB = await limiter.checkAndRecord(ip: "ip-b", success: false)
        expectAllowed(resultB, message: "IP-B should be independent of IP-A")
    }

    @Test("Locking one IP does not affect another")
    func lockingIsolation() async {
        let limiter = makeLimiter()
        _ = await limiter.checkAndRecord(ip: "ip-a", success: false)
        _ = await limiter.checkAndRecord(ip: "ip-a", success: false)

        let lockedResult = await limiter.isLockedOut(ip: "ip-a")
        expectRateLimited(lockedResult, message: "IP-A should be locked")

        let resultB = await limiter.checkAndRecord(ip: "ip-b", success: false)
        expectAllowed(resultB, message: "IP-B should not be affected by IP-A lockout")
    }

    // MARK: - Success Resets

    @Test("Success after failure resets counter")
    func successResetsCounter() async {
        let limiter = makeLimiter()
        _ = await limiter.checkAndRecord(ip: "10.0.2.1", success: false)
        _ = await limiter.checkAndRecord(ip: "10.0.2.1", success: true)

        let firstFail = await limiter.checkAndRecord(ip: "10.0.2.1", success: false)
        expectAllowed(firstFail, message: "Counter should reset after success, so first failure again is allowed")

        let secondFail = await limiter.checkAndRecord(ip: "10.0.2.1", success: false)
        expectRateLimited(secondFail, message: "Second failure after reset should lock out again")
    }

    // MARK: - Edge Cases

    @Test("Empty IP string works")
    func emptyIpString() async {
        let limiter = makeLimiter()
        let result = await limiter.checkAndRecord(ip: "", success: false)
        expectAllowed(result, message: "First failure for empty IP should be allowed")
    }

    @Test("Success on first call returns allowed without prior record")
    func successOnFirstCall() async {
        let limiter = makeLimiter()
        let result = await limiter.checkAndRecord(ip: "10.0.3.1", success: true)
        expectAllowed(result)
    }

    @Test("Rapid sequential failures while locked do not escalate")
    func rapidSequentialFailuresWhileLocked() async {
        let limiter = makeLimiter()
        let ip = "10.0.3.2"

        let result1 = await limiter.checkAndRecord(ip: ip, success: false)
        expectAllowed(result1, message: "Failure 1 should be allowed")

        let result2 = await limiter.checkAndRecord(ip: ip, success: false)
        guard let retry2 = expectRateLimited(result2, message: "Failure 2 should trigger lockout") else { return }
        #expect(retry2.components.seconds >= 0 && retry2.components.seconds <= 2)

        let result3 = await limiter.checkAndRecord(ip: ip, success: false)
        guard let retry3 = expectRateLimited(result3, message: "Failure 3 while locked returns remaining time") else { return }
        #expect(retry3 <= retry2)

        let result4 = await limiter.checkAndRecord(ip: ip, success: false)
        guard let retry4 = expectRateLimited(result4, message: "Failure 4 while locked returns remaining time") else { return }
        #expect(retry4 <= retry3)
    }

    @Test("isLockedOut returns allowed after single failure with no lockout")
    func isLockedOutAfterSingleFailure() async {
        let limiter = makeLimiter()
        _ = await limiter.checkAndRecord(ip: "10.0.4.1", success: false)
        let result = await limiter.isLockedOut(ip: "10.0.4.1")
        expectAllowed(result, message: "Single failure sets no lockout")
    }
}
