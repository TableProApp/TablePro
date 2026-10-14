//
//  AWSDiscoverySessionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

/// What Import from AWS's Continue is gated on. The discovery behind it needs a live account.
@MainActor
struct AWSDiscoverySessionTests {
    /// No config file on any machine defines it, so it resolves no region of its own.
    private let profileWithoutARegion = "tablepro-tests-\(UUID().uuidString)"

    @Test("Continue needs both a profile and a region")
    func continueNeedsAProfileAndARegion() {
        let session = AWSDiscoverySession()
        #expect(!session.canStart)

        session.profileName = profileWithoutARegion
        #expect(!session.canStart, "AWS has no default region, so a profile alone cannot start")

        session.selectedRegionIds = ["us-east-1"]
        #expect(session.canStart)

        session.profileName = "   "
        #expect(!session.canStart, "A blank profile is no profile")
    }

    /// The sheet preselects the profile's own region, so a profile without one opens on nothing.
    @Test("A profile with no region of its own leaves Continue disabled")
    func profileWithoutARegionLeavesContinueDisabled() {
        let session = AWSDiscoverySession(profileName: profileWithoutARegion)

        #expect(session.defaultRegionForProfile() == nil)
        #expect(session.selectedRegionIds.isEmpty)
        #expect(!session.canStart)
    }
}
