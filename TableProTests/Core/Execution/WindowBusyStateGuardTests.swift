//
//  WindowBusyStateGuardTests.swift
//  TableProTests
//
//  "Executing…" and the Stop control are a function of `TabExecutionRegistry` alone. A stored copy
//  kept describing work that was over whenever a path ended an execution without lowering it.
//

import Foundation
@testable import TablePro
import Testing

struct WindowBusyStateGuardTests {
    /// `ExecutionReadout.isExecuting` is computed from the registry, so reintroducing a stored `Bool`
    /// changes the memberwise initializer and this file stops compiling.
    @Test("The execution readout is a live read of the execution registry")
    func executionIndicatorReadsTheRegistry() {
        var registry = TabExecutionRegistry()
        let tab = UUID()
        let other = UUID()
        func readout(_ id: UUID) -> ExecutionReadout {
            ExecutionReadout(tabId: id, execution: registry, lastTiming: nil, onCancel: {})
        }

        let claim = registry.claim(tab)
        #expect(readout(tab).isExecuting)
        #expect(readout(other).isExecuting == false)

        /// Hoisted out of `#expect`, which evaluates its expression inside a closure that captures
        /// `registry` immutably, so a mutating call cannot go in one.
        let settled = registry.settle(claim)
        #expect(settled)
        #expect(readout(tab).isExecuting == false)

        /// Fetch All extends the result already on screen, so it registers unclaimed work rather
        /// than a claim. The readout has to count it, or Fetch All runs with no Stop button.
        let work = registry.beginUnclaimedWork(for: tab)
        #expect(readout(tab).isExecuting)
        registry.endUnclaimedWork(work, for: tab)
        #expect(readout(tab).isExecuting == false)
    }

    /// The Stop button in the status bar is a second question about the same registry: whether the
    /// work can still be stopped, which a batch whose `COMMIT` is on the wire cannot. It is part of
    /// `==` so the bar redraws when the commit phase starts.
    @Test("The readout dims its Stop while a batch is committing, and stays busy")
    func executionReadoutDimsStopWhileCommitting() {
        var registry = TabExecutionRegistry()
        let tab = UUID()
        func readout() -> ExecutionReadout {
            ExecutionReadout(tabId: tab, execution: registry, lastTiming: nil, onCancel: {})
        }

        let claim = registry.claim(tab)
        #expect(readout().isExecuting)
        #expect(readout().canStop)
        let before = readout()

        let marked = registry.enterUninterruptiblePhase(claim)
        #expect(marked)
        #expect(readout().isExecuting)
        #expect(readout().canStop == false)
        #expect(before != readout())
    }
}
