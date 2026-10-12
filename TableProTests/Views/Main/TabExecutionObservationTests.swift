//
//  TabExecutionObservationTests.swift
//  TableProTests
//
//  The editor tab strip holds the coordinator weakly and reads which tabs are busy through this
//  relay. Read through the weak reference directly, a claim opening or settling redrew nothing, so
//  a background tab's spinner followed whatever else happened to redraw the strip.
//

import Combine
import Foundation
import Testing

@testable import TablePro

@MainActor
struct TabExecutionObservationTests {
    private final class ChangeCounter {
        private(set) var sends = 0
        private var subscription: AnyCancellable?

        init(_ observation: TabExecutionObservation) {
            subscription = observation.objectWillChange.sink { [weak self] in self?.sends += 1 }
        }
    }

    private func makeCoordinator() -> MainContentCoordinator {
        MainContentCoordinator(
            connection: TestFixtures.makeConnection(),
            tabManager: QueryTabManager(),
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
    }

    @Test("a claim opening and settling each reach the observer")
    func claimLifecycleReachesObserver() {
        let coordinator = makeCoordinator()
        let observation = TabExecutionObservation(owner: coordinator)
        let counter = ChangeCounter(observation)
        let tabId = UUID()

        let claim = coordinator.tabExecution.claim(tabId)
        #expect(counter.sends == 1)
        #expect(observation.isBusy(tabId))

        _ = coordinator.tabExecution.settle(claim)
        #expect(counter.sends == 2)
        #expect(!observation.isBusy(tabId))
    }

    @Test("subscribing does not report a change")
    func subscribingIsSilent() {
        let coordinator = makeCoordinator()
        let observation = TabExecutionObservation(owner: coordinator)
        let counter = ChangeCounter(observation)

        #expect(counter.sends == 0)
    }

    @Test("no owner means no tab is busy")
    func withoutOwnerNothingIsBusy() {
        #expect(!TabExecutionObservation(owner: nil).isBusy(UUID()))
    }
}
