//
//  MCPRequestRateLimitTests.swift
//  TableProTests
//
//  Two limits, two counters. The failure limit answers guessing, the request limit answers volume,
//  and neither may stand in for the other: a client that never fails authentication can still
//  flood the server, and a locked failure bucket must not silently double as a request ban.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("MCP Request Rate Limits")
struct MCPRequestRateLimitTests {
    @Test("Failures from one address share a bucket whatever token was guessed")
    func wrongGuessesShareTheAddressBucket() async {
        let limiter = MCPRateLimiter(clock: MCPTestClock())
        let key = MCPRateLimitKey.authFailure(address: .remote("203.0.113.9"))

        for _ in 0..<4 {
            #expect(await limiter.recordAttempt(key: key, success: false) == .allowed)
        }
        guard case .lockedUntil = await limiter.recordAttempt(key: key, success: false) else {
            Issue.record("Expected the address bucket to lock")
            return
        }
        #expect(await limiter.isLocked(key: key) == true)
    }

    @Test("A validated token gets its own failure bucket")
    func tokenBucketIsSeparate() async {
        let limiter = MCPRateLimiter(clock: MCPTestClock())
        let tokenId = UUID()
        let addressKey = MCPRateLimitKey.authFailure(address: .loopback)
        let tokenKey = MCPRateLimitKey.authFailure(tokenId: tokenId)

        for _ in 0..<5 {
            _ = await limiter.recordAttempt(key: addressKey, success: false)
        }

        #expect(await limiter.isLocked(key: addressKey) == true)
        #expect(await limiter.isLocked(key: tokenKey) == false)
    }

    @Test("Concurrent requests are capped")
    func concurrencyIsCapped() async {
        let limiter = MCPRateLimiter(
            requestPolicy: MCPRequestRatePolicy(
                maxRequests: 100,
                windowDuration: .seconds(60),
                maxConcurrentRequests: 2
            ),
            clock: MCPTestClock()
        )
        let subject = MCPRateLimitSubject.token(UUID())

        #expect(await limiter.admit(subject: subject) == .admitted)
        #expect(await limiter.admit(subject: subject) == .admitted)
        #expect(
            await limiter.admit(subject: subject)
                == .rejected(retryAfterSeconds: 1, reason: .concurrencyExceeded)
        )

        await limiter.release(subject: subject)
        #expect(await limiter.admit(subject: subject) == .admitted)
    }

    @Test("The request rate is capped inside the window")
    func requestRateIsCapped() async {
        let limiter = MCPRateLimiter(
            requestPolicy: MCPRequestRatePolicy(
                maxRequests: 3,
                windowDuration: .seconds(60),
                maxConcurrentRequests: 100
            ),
            clock: MCPTestClock()
        )
        let subject = MCPRateLimitSubject.address(.loopback)

        for _ in 0..<3 {
            #expect(await limiter.admit(subject: subject) == .admitted)
            await limiter.release(subject: subject)
        }

        guard case .rejected(let retryAfterSeconds, let reason) = await limiter.admit(subject: subject) else {
            Issue.record("Expected the request rate to reject the fourth call")
            return
        }
        #expect(reason == .rateExceeded)
        #expect(retryAfterSeconds >= 1)
    }

    @Test("The window frees the rate again")
    func requestRateRecovers() async {
        let clock = MCPTestClock()
        let limiter = MCPRateLimiter(
            requestPolicy: MCPRequestRatePolicy(
                maxRequests: 1,
                windowDuration: .seconds(60),
                maxConcurrentRequests: 10
            ),
            clock: clock
        )
        let subject = MCPRateLimitSubject.address(.loopback)

        #expect(await limiter.admit(subject: subject) == .admitted)
        await limiter.release(subject: subject)
        guard case .rejected = await limiter.admit(subject: subject) else {
            Issue.record("Expected the second call to be rejected")
            return
        }

        await clock.advance(by: .seconds(61))
        #expect(await limiter.admit(subject: subject) == .admitted)
    }

    @Test("A slot is released when the operation throws")
    func slotReleasedOnThrow() async {
        let limiter = MCPRateLimiter(
            requestPolicy: MCPRequestRatePolicy(
                maxRequests: 100,
                windowDuration: .seconds(60),
                maxConcurrentRequests: 1
            ),
            clock: MCPTestClock()
        )
        let subject = MCPRateLimitSubject.token(UUID())

        await #expect(throws: MCPDataLayerError.self) {
            let work: () async throws -> Void = { throw MCPDataLayerError.userCancelled }
            try await limiter.withRequestSlot(subject: subject, operation: work)
        }
        #expect(await limiter.inFlightCount(subject: subject) == 0)
    }

    @Test("A slot that cannot be admitted is refused as a rate limit the client can retry")
    func rejectedSlotThrowsRateLimited() async throws {
        let limiter = MCPRateLimiter(
            requestPolicy: MCPRequestRatePolicy(
                maxRequests: 1,
                windowDuration: .seconds(60),
                maxConcurrentRequests: 1
            ),
            clock: MCPTestClock()
        )
        let subject = MCPRateLimitSubject.address(.loopback)
        _ = await limiter.admit(subject: subject)

        do {
            try await limiter.withRequestSlot(subject: subject) {}
            Issue.record("Expected the second slot to be refused")
        } catch let error as MCPProtocolError {
            #expect(error.code == JsonRpcErrorCode.rateLimited)
            #expect(error.httpStatus.code == 429)
            let retryAfter = try #require(error.extraHeaders.first(where: { $0.0 == "Retry-After" })?.1)
            #expect(Int(retryAfter).map { $0 >= 1 } == true)
        }
    }

    @Test("The request limit and the failure limit are counted apart")
    func requestAndFailureLimitsAreIndependent() async {
        let limiter = MCPRateLimiter(
            requestPolicy: MCPRequestRatePolicy(
                maxRequests: 2,
                windowDuration: .seconds(60),
                maxConcurrentRequests: 10
            ),
            clock: MCPTestClock()
        )
        let failureKey = MCPRateLimitKey.authFailure(address: .loopback)
        let subject = MCPRateLimitSubject.address(.loopback)

        for _ in 0..<5 {
            _ = await limiter.recordAttempt(key: failureKey, success: false)
        }
        #expect(await limiter.isLocked(key: failureKey))

        #expect(await limiter.admit(subject: subject) == .admitted)
        await limiter.release(subject: subject)

        for _ in 0..<2 {
            _ = await limiter.admit(subject: subject)
            await limiter.release(subject: subject)
        }
        #expect(await limiter.isLocked(key: failureKey))
    }

    @Test("Releasing more often than admitting never drives the count below zero")
    func releaseNeverGoesNegative() async {
        let limiter = MCPRateLimiter(clock: MCPTestClock())
        let subject = MCPRateLimitSubject.token(UUID())

        #expect(await limiter.admit(subject: subject) == .admitted)
        await limiter.release(subject: subject)
        await limiter.release(subject: subject)

        #expect(await limiter.inFlightCount(subject: subject) == 0)
        #expect(await limiter.admit(subject: subject) == .admitted)
    }

    @Test("The standard request policy is the one the server advertises")
    func standardRequestPolicy() {
        #expect(MCPRequestRatePolicy.standard.maxRequests == 240)
        #expect(MCPRequestRatePolicy.standard.windowDuration == .seconds(60))
        #expect(MCPRequestRatePolicy.standard.maxConcurrentRequests == 8)
    }
}
