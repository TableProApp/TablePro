//
//  MySQLSocketTimeoutTests.swift
//  TableProTests
//

import Testing

@Suite("MySQL Socket Timeout")
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
}
