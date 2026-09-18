//
//  MCPRateLimiterTests.swift
//  TableProTests
//
//  A failure bucket is keyed on who is failing, not on what they presented. Keying it on the
//  credential gave an attacker a fresh bucket for every guess, so the limit never fired; the
//  subject is now the address, with a second bucket per validated token so one token's misuse
//  cannot lock out the machine.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("MCP Rate Limiter")
struct MCPRateLimiterTests {
    private let attacker = MCPRateLimitKey.authFailure(address: .remote("203.0.113.9"))

    private func makeLimiter(
        maxFailedAttempts: Int = 5,
        windowSeconds: Int = 60,
        lockoutSeconds: Int = 300,
        clock: MCPTestClock
    ) -> MCPRateLimiter {
        MCPRateLimiter(
            policy: MCPRateLimitPolicy(
                maxFailedAttempts: maxFailedAttempts,
                windowDuration: .seconds(windowSeconds),
                lockoutDuration: .seconds(lockoutSeconds)
            ),
            clock: clock
        )
    }

    @Test("The standard policy locks after five failures in a minute")
    func standardPolicy() {
        #expect(MCPRateLimitPolicy.standard.maxFailedAttempts == 5)
        #expect(MCPRateLimitPolicy.standard.windowDuration == .seconds(60))
        #expect(MCPRateLimitPolicy.standard.lockoutDuration == .seconds(300))
    }

    @Test("The fifth failure locks the key")
    func fifthFailureLocks() async {
        let limiter = makeLimiter(clock: MCPTestClock())

        for _ in 0..<4 {
            #expect(await limiter.recordAttempt(key: attacker, success: false) == .allowed)
        }

        guard case .lockedUntil = await limiter.recordAttempt(key: attacker, success: false) else {
            Issue.record("Expected the fifth failure to lock the key")
            return
        }
        #expect(await limiter.isLocked(key: attacker))
    }

    @Test("A locked key stays locked while the lockout runs and frees afterwards")
    func lockoutExpires() async {
        let clock = MCPTestClock()
        let limiter = makeLimiter(maxFailedAttempts: 3, lockoutSeconds: 120, clock: clock)

        for _ in 0..<3 {
            _ = await limiter.recordAttempt(key: attacker, success: false)
        }
        #expect(await limiter.isLocked(key: attacker))

        await clock.advance(by: .seconds(119))
        #expect(await limiter.isLocked(key: attacker))

        await clock.advance(by: .seconds(2))
        #expect(await limiter.isLocked(key: attacker) == false)
        #expect(await limiter.lockedUntil(key: attacker) == nil)
    }

    @Test("A correct credential does not lift a lockout that is already running")
    func successDoesNotUnlock() async {
        let limiter = makeLimiter(clock: MCPTestClock())

        for _ in 0..<5 {
            _ = await limiter.recordAttempt(key: attacker, success: false)
        }

        guard case .lockedUntil = await limiter.recordAttempt(key: attacker, success: true) else {
            Issue.record("Expected a running lockout to survive a success")
            return
        }
        #expect(await limiter.isLocked(key: attacker))
    }

    @Test("Failures from one address share a bucket whatever credential was presented")
    func oneAddressIsOneBucket() async {
        let limiter = makeLimiter(clock: MCPTestClock())
        let sameAddress = MCPRateLimitKey.authFailure(address: .remote("203.0.113.9"))

        for _ in 0..<4 {
            _ = await limiter.recordAttempt(key: attacker, success: false)
        }

        guard case .lockedUntil = await limiter.recordAttempt(key: sameAddress, success: false) else {
            Issue.record("Expected two keys for the same address to be one bucket")
            return
        }
    }

    @Test("Two addresses are two buckets")
    func addressesAreIsolated() async {
        let limiter = makeLimiter(clock: MCPTestClock())
        let other = MCPRateLimitKey.authFailure(address: .loopback)

        for _ in 0..<5 {
            _ = await limiter.recordAttempt(key: attacker, success: false)
        }

        #expect(await limiter.isLocked(key: attacker))
        #expect(await limiter.isLocked(key: other) == false)
    }

    @Test("A validated token has a bucket of its own, separate from the address")
    func tokenBucketIsSeparate() async {
        let limiter = makeLimiter(clock: MCPTestClock())
        let tokenKey = MCPRateLimitKey.authFailure(tokenId: UUID())

        for _ in 0..<5 {
            _ = await limiter.recordAttempt(key: tokenKey, success: false)
        }

        #expect(await limiter.isLocked(key: tokenKey))
        #expect(await limiter.isLocked(key: attacker) == false)
    }

    @Test("The pairing dimension is counted apart from authentication")
    func dimensionsAreIsolated() async {
        let limiter = MCPRateLimiter(
            policy: MCPRateLimitPolicy(
                maxFailedAttempts: 5,
                windowDuration: .seconds(60),
                lockoutDuration: .seconds(300)
            ),
            pairingPolicy: MCPRateLimitPolicy(
                maxFailedAttempts: 2,
                windowDuration: .seconds(300),
                lockoutDuration: .seconds(900)
            ),
            clock: MCPTestClock()
        )
        let pairing = MCPRateLimitKey.pairingExchange(address: .loopback)
        let auth = MCPRateLimitKey.authFailure(address: .loopback)

        for _ in 0..<2 {
            _ = await limiter.recordAttempt(key: pairing, success: false)
        }

        #expect(await limiter.isLocked(key: pairing))
        #expect(await limiter.isLocked(key: auth) == false)
    }

    @Test("A success clears the failures counted so far")
    func successClearsTheCount() async {
        let limiter = makeLimiter(clock: MCPTestClock())

        for _ in 0..<4 {
            _ = await limiter.recordAttempt(key: attacker, success: false)
        }
        #expect(await limiter.recordAttempt(key: attacker, success: true) == .allowed)

        for _ in 0..<4 {
            #expect(await limiter.recordAttempt(key: attacker, success: false) == .allowed)
        }
        #expect(await limiter.isLocked(key: attacker) == false)
    }

    @Test("Failures that fall out of the window stop counting")
    func failuresExpireWithTheWindow() async {
        let clock = MCPTestClock()
        let limiter = makeLimiter(windowSeconds: 60, clock: clock)

        for _ in 0..<4 {
            _ = await limiter.recordAttempt(key: attacker, success: false)
        }
        await clock.advance(by: .seconds(61))

        #expect(await limiter.recordAttempt(key: attacker, success: false) == .allowed)
        #expect(await limiter.isLocked(key: attacker) == false)
    }

    @Test("Retry-after is at least a second and counts down with the clock")
    func retryAfterCountsDown() async {
        let clock = MCPTestClock()
        let limiter = makeLimiter(maxFailedAttempts: 1, lockoutSeconds: 300, clock: clock)

        _ = await limiter.recordAttempt(key: attacker, success: false)
        let unlockDate = await limiter.lockedUntil(key: attacker)
        let unlock = unlockDate ?? Date.now

        #expect(await limiter.retryAfterSeconds(until: unlock) == 300)
        await clock.advance(by: .seconds(299))
        #expect(await limiter.retryAfterSeconds(until: unlock) == 1)
        await clock.advance(by: .seconds(10))
        #expect(await limiter.retryAfterSeconds(until: unlock) == 1)
    }

    @Test("Resetting a key clears its lockout without touching the others")
    func resetClearsOneBucket() async {
        let limiter = makeLimiter(clock: MCPTestClock())
        let other = MCPRateLimitKey.authFailure(address: .loopback)

        for _ in 0..<5 {
            _ = await limiter.recordAttempt(key: attacker, success: false)
            _ = await limiter.recordAttempt(key: other, success: false)
        }

        await limiter.reset(key: attacker)

        #expect(await limiter.isLocked(key: attacker) == false)
        #expect(await limiter.isLocked(key: other))
    }

    @Test("Clearing everything drops every bucket")
    func clearAllDropsEveryBucket() async {
        let limiter = makeLimiter(clock: MCPTestClock())
        let other = MCPRateLimitKey.authFailure(tokenId: UUID())

        for _ in 0..<5 {
            _ = await limiter.recordAttempt(key: attacker, success: false)
            _ = await limiter.recordAttempt(key: other, success: false)
        }

        await limiter.clearAll()

        #expect(await limiter.isLocked(key: attacker) == false)
        #expect(await limiter.isLocked(key: other) == false)
    }

    @Test("A key names its subject and its dimension in the log")
    func keysDescribeThemselves() {
        let tokenId = UUID()

        #expect(MCPRateLimitSubject.address(.loopback).describedValue == "address:127.0.0.1")
        #expect(MCPRateLimitSubject.address(.remote("10.0.0.1")).describedValue == "address:10.0.0.1")
        #expect(MCPRateLimitSubject.token(tokenId).describedValue == "token:\(tokenId.uuidString)")
        #expect(MCPRateLimitKey.authFailure(address: .loopback).dimension == .authFailure)
        #expect(MCPRateLimitKey.pairingExchange(address: .loopback).dimension == .pairingExchange)
    }
}
