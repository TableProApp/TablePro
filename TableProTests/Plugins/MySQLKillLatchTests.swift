//
//  MySQLKillLatchTests.swift
//  TableProTests
//
//  The live behaviour this latch encodes was measured with the app's own libmariadb against seven
//  servers; see MySQLKillLatch.swift.
//

import Testing

struct MySQLKillLatchTests {
    @Test("Nothing to absorb before a kill has gone out")
    func idleLatchAbsorbsNothing() {
        var latch = MySQLKillLatch()
        #expect(latch.takeAbsorption() == false)
    }

    /// The common case after Stop. A killed `SELECT` is caught by the cancellation gate in the fetch
    /// loop, which throws `CancellationError` without ever reading the server's errno, so the kill
    /// is delivered and nothing reports it as collected.
    @Test("A delivered kill nobody reported is absorbed")
    func deliveredKillIsAbsorbed() {
        var latch = MySQLKillLatch()
        latch.recordDelivered(generation: 7)
        let absorbed = latch.takeAbsorption()
        #expect(absorbed)
    }

    @Test("A kill the statement itself collected is not absorbed again")
    func interruptedKillIsNotAbsorbed() {
        var latch = MySQLKillLatch()
        latch.recordDelivered(generation: 7)
        latch.recordInterrupted(generation: 7)
        #expect(latch.takeAbsorption() == false)
    }

    /// The kill goes out on the cancel queue while the statement reads its error on the statement
    /// queue, so neither ordering is guaranteed and both have to answer the same.
    @Test("The interruption may be recorded before the delivery")
    func orderDoesNotMatter() {
        var latch = MySQLKillLatch()
        latch.recordInterrupted(generation: 7)
        latch.recordDelivered(generation: 7)
        #expect(latch.takeAbsorption() == false)
    }

    /// An interruption belonging to an earlier statement says nothing about the kill just sent.
    @Test("An interruption from another generation does not clear the latch")
    func staleInterruptionDoesNotClear() {
        var latch = MySQLKillLatch()
        latch.recordInterrupted(generation: 6)
        latch.recordDelivered(generation: 7)
        let absorbed = latch.takeAbsorption()
        #expect(absorbed)
    }

    @Test("Taking the answer clears it, so one kill is absorbed once")
    func takingClearsTheLatch() {
        var latch = MySQLKillLatch()
        latch.recordDelivered(generation: 7)
        let first = latch.takeAbsorption()
        #expect(first)
        #expect(latch.takeAbsorption() == false)
    }

    /// Only the two engines measured to hold an idle kill pay the round trip.
    @Test("MySQL and MariaDB absorb a latched kill, the other flavours do not")
    func onlyMeasuredFlavoursAbsorb() {
        #expect(MySQLKillLatch.absorbsLatchedKill(flavor: .mysql))
        #expect(MySQLKillLatch.absorbsLatchedKill(flavor: .mariadb))
        #expect(MySQLKillLatch.absorbsLatchedKill(flavor: .tidb(version: nil)) == false)
        #expect(MySQLKillLatch.absorbsLatchedKill(flavor: .databend) == false)
        #expect(MySQLKillLatch.absorbsLatchedKill(flavor: .oceanbase(version: nil)) == false)
    }
}
