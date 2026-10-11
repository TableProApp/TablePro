//
//  MySQLSocketTimeoutTests.swift
//  TableProTests
//

import Testing

struct MySQLSocketTimeoutTests {
    @Test("No limit maps to an infinite socket timeout")
    func noLimitIsInfinite() {
        #expect(mysqlSocketTimeoutSeconds(forQueryTimeout: 0) == 0)
    }

    @Test("A negative query timeout maps to an infinite socket timeout")
    func negativeIsInfinite() {
        #expect(mysqlSocketTimeoutSeconds(forQueryTimeout: -5) == 0)
    }

    @Test("A finite query timeout adds the grace period")
    func finiteAddsGrace() {
        #expect(mysqlSocketTimeoutSeconds(forQueryTimeout: 60) == 90)
        #expect(mysqlSocketTimeoutSeconds(forQueryTimeout: 600) == 630)
    }

    @Test("The grace period is applied on top of the query timeout")
    func graceMatchesConstant() {
        #expect(mysqlSocketTimeoutSeconds(forQueryTimeout: 1) == UInt32(1 + mysqlSocketTimeoutGraceSeconds))
    }

    @Test("A very large query timeout clamps without overflowing")
    func largeValueClamps() {
        #expect(mysqlSocketTimeoutSeconds(forQueryTimeout: Int.max) == UInt32.max)
    }

    @Test("An infinite socket timeout can never be what a failure waited for")
    func infiniteTimeoutNeverOutlasted() {
        #expect(!mysqlWaitCouldOutlastSocketTimeout(.seconds(0), socketTimeoutSeconds: 0))
        #expect(!mysqlWaitCouldOutlastSocketTimeout(.seconds(3_600), socketTimeoutSeconds: 0))
    }

    @Test("A wait reaches the socket timeout exactly on it, and not a millisecond before")
    func boundary() {
        #expect(mysqlWaitCouldOutlastSocketTimeout(.seconds(90), socketTimeoutSeconds: 90))
        #expect(mysqlWaitCouldOutlastSocketTimeout(.seconds(91), socketTimeoutSeconds: 90))
        #expect(!mysqlWaitCouldOutlastSocketTimeout(.milliseconds(89_999), socketTimeoutSeconds: 90))
    }
}

struct MySQLConnectTimeoutTests {
    @Test("The remaining millisecond budget takes priority and rounds up for libmariadb")
    func millisecondsReachNativeSeconds() {
        let timeout = MySQLConnectTimeout(additionalFields: [
            "connectTimeoutMilliseconds": "1251",
            "connectTimeoutSeconds": "9"
        ])

        #expect(timeout.milliseconds == 1_251)
        #expect(timeout.nativeSeconds == 2)
    }

    @Test("The compatibility seconds value is checked and clamped")
    func secondsFallbackClamps() {
        #expect(MySQLConnectTimeout(additionalFields: [:]).milliseconds == 30_000)
        #expect(MySQLConnectTimeout(additionalFields: ["connectTimeoutSeconds": "12"]).milliseconds == 12_000)
        #expect(MySQLConnectTimeout(additionalFields: ["connectTimeoutSeconds": "-2"]).milliseconds == 1)
        #expect(
            MySQLConnectTimeout(additionalFields: ["connectTimeoutSeconds": String(Int.max)]).milliseconds
                == MySQLConnectTimeout.maximumMilliseconds
        )
    }

    @Test("The connect budget is independent from the query socket timeout")
    func connectBudgetDoesNotUseQueryTimeout() {
        let startedAt = ContinuousClock.now
        let deadline = MySQLConnectDeadline(
            timeout: MySQLConnectTimeout(milliseconds: 600_000),
            startedAt: startedAt
        )

        #expect(deadline.socketTimeoutSeconds(at: startedAt) == 600)
        #expect(deadline.socketTimeoutSeconds(at: startedAt.advanced(by: .seconds(31))) == 569)
        #expect(mysqlSocketTimeoutSeconds(forQueryTimeout: 1) == 31)
    }

    @Test("Every required connect operation receives only the remaining budget")
    func requiredOperationsShareDeadline() {
        let startedAt = ContinuousClock.now
        let deadline = MySQLConnectDeadline(
            timeout: MySQLConnectTimeout(milliseconds: 90_000),
            startedAt: startedAt
        )

        #expect(deadline.socketTimeoutSeconds(at: startedAt.advanced(by: .seconds(60))) == 30)
        #expect(deadline.socketTimeoutSeconds(at: startedAt.advanced(by: .milliseconds(89_100))) == 1)
        #expect(deadline.socketTimeoutSeconds(at: startedAt.advanced(by: .seconds(90))) == nil)
    }

    @Test("A reconnect gets a fresh connect budget without changing query semantics")
    func reconnectGetsFreshDeadline() {
        let firstStart = ContinuousClock.now
        let timeout = MySQLConnectTimeout(milliseconds: 30_000)
        let firstDeadline = MySQLConnectDeadline(timeout: timeout, startedAt: firstStart)
        let reconnectStart = firstStart.advanced(by: .seconds(30))
        let reconnectDeadline = MySQLConnectDeadline(timeout: timeout, startedAt: reconnectStart)

        #expect(firstDeadline.socketTimeoutSeconds(at: reconnectStart) == nil)
        #expect(reconnectDeadline.socketTimeoutSeconds(at: reconnectStart) == 30)
        #expect(mysqlSocketTimeoutSeconds(forQueryTimeout: 60) == 90)
    }
}
