//
//  MySQLKillLatchTests.swift
//  TableProTests
//
//  `MariaDBPluginConnection` is not compiled into the test target, so the ordering is pinned here on
//  the pure latch the connection asks. The live behaviour it encodes was measured with the app's own
//  libmariadb against seven servers; see MySQLKillLatch.swift.
//

import Foundation
import Testing

@Suite("MySQL kill latch")
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

/// The absorb step has to sit where every statement passes, not beside one of them. `streamQuery`
/// was the gap the design left: an export right after a Stop collected the kill instead.
@Suite("MySQL statement entry points")
struct MySQLStatementEntryPointGuardTests {
    @Test("Every statement entry point goes through the wrapper that absorbs a latched kill")
    func everyStatementEntryPointUsesTheWrapper() throws {
        let source = try Self.connectionSource()
        let wrapped = Self.lines(of: source).filter { $0.contains("try runStatement(") }
        #expect(
            wrapped.count == 3,
            """
            executeQuerySync, executeParameterizedQuerySync and streamQuery each wrap their body in \
            runStatement, which is the one place absorbLatchedKillIfNeeded runs. A fourth statement \
            path needs the same wrapper: \(wrapped)
            """
        )
        #expect(source.contains("absorbLatchedKillIfNeeded()"))
    }

    /// The absorb is useless if the kill has not gone out yet, so the drain is part of it.
    @Test("Absorbing drains the cancel queue before reading the latch")
    func absorbDrainsTheCancelQueueFirst() throws {
        let source = try Self.connectionSource()
        let body = try #require(source.range(of: "func absorbLatchedKillIfNeeded() {"))
        let tail = source[body.upperBound...].prefix(400)
        let drain = try #require(tail.range(of: "cancelQueue.sync {}"))
        let read = try #require(tail.range(of: "takeKillAbsorption()"))
        #expect(drain.lowerBound < read.lowerBound)
    }

    private static func lines(of source: String) -> [String] {
        source.components(separatedBy: .newlines)
    }

    private static func connectionSource() throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 12 {
            let candidate = directory
                .appendingPathComponent("Plugins/MySQLDriverPlugin/MariaDBPluginConnection.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            directory = directory.deletingLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
