//
//  MySQLStatementWatchTests.swift
//  TableProTests
//

import Dispatch
import Foundation
import Testing

struct MySQLStatementWatchTests {
    @Test("An expiry while the statement runs interrupts once, and end reports it")
    func expiryWhileRunning() {
        let watch = MySQLStatementWatch()
        let token = watch.begin()
        var interrupts = 0
        watch.expire(token) {
            interrupts += 1
            return true
        }
        #expect(interrupts == 1)
        #expect(watch.end(token))
    }

    @Test("An expiry after the statement ended never interrupts")
    func expiryAfterEnd() {
        let watch = MySQLStatementWatch()
        let token = watch.begin()
        #expect(!watch.end(token))
        var interrupts = 0
        watch.expire(token) {
            interrupts += 1
            return true
        }
        #expect(interrupts == 0)
        #expect(!watch.end(token))
    }

    @Test("An expiry for a token a later statement replaced never interrupts")
    func staleToken() {
        let watch = MySQLStatementWatch()
        let first = watch.begin()
        _ = watch.end(first)
        let second = watch.begin()
        var interrupts = 0
        watch.expire(first) {
            interrupts += 1
            return true
        }
        #expect(interrupts == 0)
        #expect(!watch.end(second))
        #expect(!watch.isRunning(second))
    }

    @Test("An interrupt that could not be sent leaves end reporting nothing to consume")
    func failedInterrupt() {
        let watch = MySQLStatementWatch()
        let token = watch.begin()
        watch.expire(token) { false }
        #expect(!watch.end(token))
    }

    @Test("A kill is reported once, so only the statement that saw it consumes the flag")
    func interruptConsumedOnce() {
        let watch = MySQLStatementWatch()
        let token = watch.begin()
        watch.expire(token) { true }
        #expect(watch.end(token))
        #expect(!watch.end(token))
    }

    /// The whole point of holding the lock across the interrupt: the statement cannot finish, and
    /// therefore the next statement on the serial queue cannot start, while a kill is in flight.
    @Test("end waits for an interrupt that is still in flight")
    func endWaitsForInterrupt() {
        let watch = MySQLStatementWatch()
        let token = watch.begin()
        let ended = DispatchSemaphore(value: 0)
        let interruptStarted = DispatchSemaphore(value: 0)
        let endResult = MySQLStatementWatchTestBox()

        watch.expire(token) {
            DispatchQueue.global().async {
                interruptStarted.signal()
                endResult.value = watch.end(token)
                ended.signal()
            }
            interruptStarted.wait()
            #expect(ended.wait(timeout: .now() + .milliseconds(50)) == .timedOut)
            return true
        }

        #expect(ended.wait(timeout: .now() + .seconds(5)) == .success)
        #expect(endResult.value)
    }
}

private final class MySQLStatementWatchTestBox: @unchecked Sendable {
    var value = false
}
