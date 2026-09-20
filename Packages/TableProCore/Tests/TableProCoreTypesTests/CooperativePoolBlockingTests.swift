//
//  CooperativePoolBlockingTests.swift
//  TableProCoreTypesTests
//
//  The shape behind the SSH tunnel's accept and relay loops. A tunnel spends most of its life
//  inside a blocking `poll`, and Swift's cooperative pool is as wide as `activeProcessorCount`,
//  so a tunnel that blocks on it takes a thread the whole app shares. Measured: 48 tunnels
//  blocking inside an actor method ran 12 at a time and took 4,005ms; `Task.detached` measured
//  the same 12 and 4,006ms because it is the same pool. Handing the blocking call to a
//  DispatchQueue of its own ran all 48 at once in 1,003ms.
//

import Foundation
import Testing

@testable import TableProCoreTypes

@Suite("Cooperative pool blocking", .serialized)
struct CooperativePoolBlockingTests {
    /// Wider than the cooperative pool on every machine this runs on, so a shape that borrows
    /// cooperative threads has to run in waves and a shape that does not, does not.
    private static var blockerCount: Int { ProcessInfo.processInfo.activeProcessorCount + 4 }
    private static let blockMilliseconds = 300

    @Test("Blocking through its own queue runs every caller at once")
    func runsEveryBlockerConcurrently() async throws {
        let peak = ConcurrencyPeak()
        let started = Date()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0 ..< Self.blockerCount {
                group.addTask {
                    let queue = DispatchQueue(label: "test.blocker.\(index)")
                    try await runCancellableBlocking(
                        on: queue,
                        work: {
                            peak.enter()
                            usleep(UInt32(Self.blockMilliseconds) * 1_000)
                            peak.leave()
                        }
                    )
                }
            }
            try await group.waitForAll()
        }

        let elapsed = Date().timeIntervalSince(started)
        #expect(peak.highWaterMark == Self.blockerCount)
        #expect(elapsed < Double(Self.blockMilliseconds * 3) / 1_000)
    }

    @Test("Blocking a detached task instead caps at the cooperative pool width")
    func detachedTaskIsNotAnEscapeHatch() async {
        let peak = ConcurrencyPeak()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< Self.blockerCount {
                group.addTask {
                    await Task.detached {
                        peak.enter()
                        usleep(UInt32(Self.blockMilliseconds) * 1_000)
                        peak.leave()
                    }.value
                }
            }
            await group.waitForAll()
        }

        #expect(peak.highWaterMark < Self.blockerCount)
    }
}

private final class ConcurrencyPeak: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var peak = 0

    var highWaterMark: Int {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }

    func enter() {
        lock.lock()
        current += 1
        peak = max(peak, current)
        lock.unlock()
    }

    func leave() {
        lock.lock()
        current -= 1
        lock.unlock()
    }
}
