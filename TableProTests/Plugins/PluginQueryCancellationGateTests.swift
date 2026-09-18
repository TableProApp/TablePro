//
//  PluginQueryCancellationGateTests.swift
//  TableProTests
//

@testable import TableProPluginKit
import Testing

@Suite("Plugin query cancellation gate")
struct PluginQueryCancellationGateTests {
    @Test("Cancelling while no query is running is a no-op")
    func cancelWhileIdleReturnsNil() {
        let gate = PluginQueryCancellationGate()

        #expect(gate.cancel() == nil)
    }

    @Test("Cancelling while a query is running reports that query")
    func cancelWhileActiveReturnsTheActiveGeneration() {
        let gate = PluginQueryCancellationGate()
        let generation = gate.beginQuery()

        #expect(gate.cancel() == generation)
        #expect(gate.isCancelled(generation))
    }

    @Test("A cancel never reaches a query issued after it")
    func cancelDoesNotLeakIntoTheNextQuery() {
        let gate = PluginQueryCancellationGate()
        let first = gate.beginQuery()
        gate.cancel()
        gate.endQuery(first)

        let second = gate.beginQuery()

        #expect(gate.isCancelled(first))
        #expect(gate.isCancelled(second) == false)
    }

    @Test("Cancelling after a query finished is a no-op")
    func cancelAfterEndQueryIsANoOp() {
        let gate = PluginQueryCancellationGate()
        let generation = gate.beginQuery()
        gate.endQuery(generation)

        #expect(gate.cancel() == nil)
        #expect(gate.isCancelled(generation) == false)
    }

    @Test("A query returning no rows leaves nothing armed for the next one")
    func aQueryThatConsumesNothingLeavesTheGateIdle() {
        let gate = PluginQueryCancellationGate()
        let first = gate.beginQuery()
        gate.cancel()
        gate.endQuery(first)

        let second = gate.beginQuery()
        gate.endQuery(second)

        #expect(gate.cancel() == nil)
        #expect(gate.isCancelled(second) == false)
    }

    @Test("Ending a superseded query does not clear the running one")
    func endQueryIgnoresAStaleGeneration() {
        let gate = PluginQueryCancellationGate()
        let first = gate.beginQuery()
        let second = gate.beginQuery()

        gate.endQuery(first)

        #expect(gate.cancel() == second)
    }
}
