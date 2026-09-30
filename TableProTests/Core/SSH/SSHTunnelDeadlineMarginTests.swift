//
//  SSHTunnelDeadlineMarginTests.swift
//  TableProTests
//
//  Guards the absolute deadline shared by the first tunnel client and the fresh configured
//  budget each later metadata client receives.
//

import Foundation
@testable import TablePro
import Testing

struct SSHTunnelDeadlineMarginTests {
    @Test("The first relay keeps the original deadline and a second gets the configured 60 seconds")
    func secondaryRelayGetsConfiguredBudget() {
        let startedAt = ContinuousClock.now
        let initial = ConnectionDeadline(configuredSeconds: 60, startedAt: startedAt)
        let provider = ConnectionRelayDeadlineProvider(initialDeadline: initial)

        let first = provider.next(startedAt: startedAt.advanced(by: .seconds(10)))
        let secondStart = startedAt.advanced(by: .seconds(20))
        let second = provider.next(startedAt: secondStart)

        #expect(first.isInitial)
        #expect(first.deadline == initial)
        #expect(!second.isInitial)
        #expect(second.deadline.configuredSeconds == 60)
        #expect(second.deadline.instant == secondStart.advanced(by: .seconds(60)))
    }

    @Test("The accept loop notices a waiting client well inside the margin")
    func acceptPollIsShort() {
        #expect(LibSSH2Tunnel.acceptPollTimeoutMs <= 200)
        #expect(LibSSH2Tunnel.acceptPollTimeoutMs > 0)
    }
}
