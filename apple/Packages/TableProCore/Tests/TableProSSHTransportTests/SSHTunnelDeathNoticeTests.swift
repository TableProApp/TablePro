//
//  SSHTunnelDeathNoticeTests.swift
//  TableProSSHTransportTests
//

import Foundation
import os
import Testing

@testable import TableProSSHTransport

struct SSHTunnelDeathNoticeTests {
    @Test("A death reaches the handler set before it")
    func reportsToEarlierHandler() {
        let notice = SSHTunnelDeathNotice()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        notice.onDeath { calls.withLock { $0 += 1 } }

        notice.died()

        #expect(calls.withLock { $0 } == 1)
    }

    @Test("A handler set after the death still hears of it")
    func reportsToLateHandler() {
        let notice = SSHTunnelDeathNotice()
        notice.died()

        let calls = OSAllocatedUnfairLock(initialState: 0)
        notice.onDeath { calls.withLock { $0 += 1 } }

        #expect(calls.withLock { $0 } == 1)
    }

    @Test("A second death is not reported again")
    func reportsOnce() {
        let notice = SSHTunnelDeathNotice()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        notice.onDeath { calls.withLock { $0 += 1 } }

        notice.died()
        notice.died()

        #expect(calls.withLock { $0 } == 1)
    }

    @Test("No death, no report")
    func silentWhileAlive() {
        let notice = SSHTunnelDeathNotice()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        notice.onDeath { calls.withLock { $0 += 1 } }

        #expect(calls.withLock { $0 } == 0)
    }
}
