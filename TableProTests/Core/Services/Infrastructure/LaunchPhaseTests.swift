//
//  LaunchPhaseTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct LaunchPhaseTests {
    @Test
    func launchingAndCollectingAcceptIntents() {
        #expect(LaunchPhase.launching.isAcceptingIntents)
        #expect(LaunchPhase.collectingIntents.isAcceptingIntents)
    }

    @Test
    func routingAndReadyRefuseIntents() {
        #expect(!LaunchPhase.routing.isAcceptingIntents)
        #expect(!LaunchPhase.ready.isAcceptingIntents)
    }

    @Test
    func onlyReadyReportsReady() {
        #expect(!LaunchPhase.launching.isReady)
        #expect(!LaunchPhase.collectingIntents.isReady)
        #expect(!LaunchPhase.routing.isReady)
        #expect(LaunchPhase.ready.isReady)
    }
}
