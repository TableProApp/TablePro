//
//  LicenseSyncPresentationTests.swift
//  TablePro
//

import Foundation
import TableProSyncTransport
@testable import TablePro
import Testing

struct LicenseSyncPresentationTests {
    @Test("Available iCloud Sync leaves sync on")
    func availableHasNoDisableReason() {
        #expect(SyncProviderCoordinator.licenseDisableReason(for: .available) == nil)
    }

    @Test("An entitlement that could not be refreshed pauses sync as its own reason, not one that needs buying")
    func refreshFailureHasItsOwnDisableReason() {
        #expect(SyncProviderCoordinator.licenseDisableReason(for: .refreshFailed) == .licenseUnverified)
        #expect(SyncProviderCoordinator.licenseDisableReason(for: .expired) == .licenseExpired)
    }

    @Test("Signed out and not included both ask for a license")
    func remainingStatesRequireALicense() {
        #expect(SyncProviderCoordinator.licenseDisableReason(for: .signedOut) == .licenseRequired)
        #expect(SyncProviderCoordinator.licenseDisableReason(for: .notIncluded) == .licenseRequired)
    }
}
