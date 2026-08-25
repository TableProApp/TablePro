//
//  LicenseSyncPresentationTests.swift
//  TablePro
//
//  The grids that used to be `default:` arms. Each one had exactly one status it answered wrongly,
//  and it was the same status every time: a paying customer the app has not reached the server
//  about.
//

import Foundation
import SwiftUI
import TableProSyncTransport
@testable import TablePro
import Testing

@Suite("License state presentation")
struct LicenseSyncPresentationTests {
    private static let everyStatus: [LicenseStatus] = [
        .unlicensed, .active, .expired, .suspended, .deactivated, .validationFailed
    ]

    @Test("An unverified license pauses sync as its own reason, not as one that needs buying")
    func unverifiedLicenseHasItsOwnDisableReason() {
        #expect(SyncCoordinator.licenseDisableReason(for: .validationFailed) == .licenseUnverified)
        #expect(SyncCoordinator.licenseDisableReason(for: .expired) == .licenseExpired)
    }

    @Test("Every other status still asks for a license")
    func remainingStatusesRequireALicense() {
        for status in [LicenseStatus.unlicensed, .suspended, .deactivated, .active] {
            #expect(SyncCoordinator.licenseDisableReason(for: status) == .licenseRequired)
        }
    }

    @Test("No status maps to a reason that would offer the wrong way out")
    func everyStatusIsAnswered() {
        let reasons = Self.everyStatus.map { SyncCoordinator.licenseDisableReason(for: $0) }

        #expect(reasons.count == Self.everyStatus.count)
        #expect(!reasons.contains(.noAccount))
        #expect(!reasons.contains(.userDisabled))
    }

    @Test("An unverified license reads as a warning, never as a failure")
    func statusColorSeparatesUnverifiedFromGone() {
        #expect(LicenseSection.statusColor(for: .active) == .green)
        #expect(LicenseSection.statusColor(for: .validationFailed) == .orange)

        for status in [LicenseStatus.unlicensed, .expired, .suspended, .deactivated] {
            #expect(LicenseSection.statusColor(for: status) == .red)
        }
    }

    @Test("A license that already lapsed is not expiring soon")
    func expiredLicenseIsNotExpiringSoon() {
        #expect(!LicenseManager.isExpiringSoon(daysUntilExpiry: 0, isExpired: true))
        #expect(!LicenseManager.isExpiringSoon(daysUntilExpiry: -3, isExpired: true))
    }

    @Test("The renewal warning covers the last seven days and stops there")
    func expiringSoonWindow() {
        #expect(LicenseManager.isExpiringSoon(daysUntilExpiry: 0, isExpired: false))
        #expect(LicenseManager.isExpiringSoon(daysUntilExpiry: 7, isExpired: false))
        #expect(!LicenseManager.isExpiringSoon(daysUntilExpiry: 8, isExpired: false))
        #expect(!LicenseManager.isExpiringSoon(daysUntilExpiry: -1, isExpired: false))
    }

    @Test("A lifetime license never warns about renewal")
    func lifetimeLicenseNeverExpiresSoon() {
        #expect(!LicenseManager.isExpiringSoon(daysUntilExpiry: nil, isExpired: false))
    }
}
