import Foundation
import Testing

@testable import TableProMSSQLCore

@Suite("MSSQL request gate")
struct MSSQLRequestGateTests {
    @Test("A Stop cancels every call made before it and none made after")
    func stopCancelsEarlierCallsOnly() {
        let gate = MSSQLRequestGate()
        let first = gate.enqueue()
        let second = gate.enqueue()
        gate.stop()
        let third = gate.enqueue()

        #expect(gate.isCancelled(first))
        #expect(gate.isCancelled(second))
        #expect(!gate.isCancelled(third))
    }

    @Test("A call stopped while it waited never sends its request")
    func stoppedCallNeverBegins() throws {
        let gate = MSSQLRequestGate()
        let running = gate.enqueue()
        try gate.beginRequest(running)
        let waiting = gate.enqueue()
        gate.stop()
        gate.endRequest()

        #expect(throws: CancellationError.self) { try gate.beginRequest(waiting) }
    }

    @Test("A call made after a Stop runs")
    func callAfterStopBegins() throws {
        let gate = MSSQLRequestGate()
        _ = gate.enqueue()
        gate.stop()
        let next = gate.enqueue()

        try gate.beginRequest(next)
        #expect(!gate.isInterruptRaised)
    }

    @Test("A Stop with no request on the wire raises no interrupt")
    func stopBetweenRequestsRaisesNoInterrupt() {
        let gate = MSSQLRequestGate()
        _ = gate.enqueue()
        gate.stop()

        #expect(!gate.isInterruptRaised)
        #expect(!gate.takeInterrupt())
    }

    @Test("A Stop while a request is on the wire raises the interrupt, and it is taken once")
    func stopDuringRequestRaisesOneInterrupt() throws {
        let gate = MSSQLRequestGate()
        let call = gate.enqueue()
        try gate.beginRequest(call)
        gate.stop()

        #expect(gate.isInterruptRaised)
        #expect(gate.takeInterrupt())
        #expect(!gate.isInterruptRaised)
        #expect(!gate.takeInterrupt())
        #expect(gate.isCancelled(call))
    }

    @Test("An interrupt ends with the request that raised it")
    func interruptNeverReachesTheNextRequest() throws {
        let gate = MSSQLRequestGate()
        let stopped = gate.enqueue()
        try gate.beginRequest(stopped)
        gate.stop()
        gate.endRequest()

        #expect(!gate.isInterruptRaised)

        let next = gate.enqueue()
        try gate.beginRequest(next)

        #expect(!gate.isInterruptRaised)
        #expect(!gate.takeInterrupt())
        #expect(!gate.isCancelled(next))
    }

    @Test("A Stop from other threads reaches the call on the wire")
    func stopFromAnotherThread() async throws {
        let gate = MSSQLRequestGate()
        let call = gate.enqueue()
        try gate.beginRequest(call)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { gate.stop() }
            }
        }

        #expect(gate.isCancelled(call))
        #expect(gate.takeInterrupt())
        #expect(!gate.takeInterrupt())
    }
}
