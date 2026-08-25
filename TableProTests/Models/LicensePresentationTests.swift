//
//  LicensePresentationTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("LicensePresentation")
struct LicensePresentationTests {
    // MARK: - Which layout the pane shows

    @Test("Only an active license shows the licensed layout")
    func activeShowsLicensedLayout() {
        #expect(LicensePresentation.showsLicensedLayout(status: .active))
    }

    @Test("Every state that is not active offers the way back in, not license details")
    func lapsedStatesShowTheLandingState() {
        let lapsed: [LicenseStatus] = [.unlicensed, .expired, .suspended, .deactivated, .validationFailed]
        for status in lapsed {
            #expect(
                LicensePresentation.showsLicensedLayout(status: status) == false,
                "\(status.rawValue) should show the landing state so a renewal key can be entered"
            )
        }
    }

    // MARK: - Notices

    @Test("A healthy license with no expiry in sight says nothing")
    func activeLicenseHasNoNotice() {
        let notice = LicensePresentation.notice(status: .active, daysUntilExpiry: 90, hasLicense: true)
        #expect(notice == nil)
    }

    @Test("A lifetime license never warns about expiry")
    func lifetimeLicenseHasNoNotice() {
        let notice = LicensePresentation.notice(status: .active, daysUntilExpiry: nil, hasLicense: true)
        #expect(notice == nil)
    }

    @Test("Expiry is raised inside the last week and not before")
    func expiryWarningWindow() {
        let eightDays = LicensePresentation.notice(status: .active, daysUntilExpiry: 8, hasLicense: true)
        #expect(eightDays == nil)

        let sevenDays = LicensePresentation.notice(status: .active, daysUntilExpiry: 7, hasLicense: true)
        #expect(sevenDays?.action == .renew)
        #expect(sevenDays?.tone == .informational)

        let today = LicensePresentation.notice(status: .active, daysUntilExpiry: 0, hasLicense: true)
        #expect(today?.action == .renew)
    }

    @Test("An expired license offers renewal")
    func expiredOffersRenewal() {
        let notice = LicensePresentation.notice(status: .expired, daysUntilExpiry: -3, hasLicense: true)
        #expect(notice?.action == .renew)
        #expect(notice?.tone == .warning)
    }

    @Test("A suspended license offers no self-service action")
    func suspendedOffersNoAction() {
        let notice = LicensePresentation.notice(status: .suspended, daysUntilExpiry: nil, hasLicense: true)
        #expect(notice?.action == nil)
        #expect(notice?.tone == .critical)
    }

    @Test("A license that ran out of offline grace offers to try the server again")
    func validationFailedOffersRetry() {
        let notice = LicensePresentation.notice(status: .validationFailed, daysUntilExpiry: nil, hasLicense: true)
        #expect(notice?.action == .retryValidation)
    }

    @Test("A Mac whose seat was given up is told so, rather than looking like it never had one")
    func deactivatedIsDistinctFromUnlicensed() {
        let deactivated = LicensePresentation.notice(status: .deactivated, daysUntilExpiry: nil, hasLicense: false)
        #expect(deactivated?.action == .activate)

        let neverLicensed = LicensePresentation.notice(status: .unlicensed, daysUntilExpiry: nil, hasLicense: false)
        #expect(neverLicensed == nil, "Somebody who never bought a license is not in a degraded state")
    }

    @Test("A key the server no longer knows is reported rather than silently blank")
    func unlicensedWithARecordIsReported() {
        let notice = LicensePresentation.notice(status: .unlicensed, daysUntilExpiry: nil, hasLicense: true)
        #expect(notice?.action == .purchase)
    }

    @Test("Every status resolves without trapping")
    func everyStatusIsCovered() {
        let all: [LicenseStatus] = [.unlicensed, .active, .expired, .suspended, .deactivated, .validationFailed]
        for status in all {
            for hasLicense in [true, false] {
                _ = LicensePresentation.notice(status: status, daysUntilExpiry: 3, hasLicense: hasLicense)
            }
        }
    }

    // MARK: - Key masking

    @Test("A key is masked to its first group, so a screen share never carries the whole credential")
    func maskedKeyKeepsOnlyTheFirstGroup() {
        let masked = LicensePresentation.maskedKey("ABCDE-FGHIJ-KLMNO-PQRST-UVWXY")
        #expect(masked == "ABCDE-•••••-•••••-•••••-•••••")
        #expect(masked.contains("FGHIJ") == false)
    }

    @Test("A key that is not the expected shape is left alone rather than mangled")
    func maskedKeyPassesThroughAnUnexpectedShape() {
        #expect(LicensePresentation.maskedKey("SHORT") == "SHORT")
        #expect(LicensePresentation.maskedKey("") == "")
    }

    // MARK: - Counts

    @Test("Counts come from a format string with positional arguments, so a translation can reorder them")
    func countsAreFormatted() {
        #expect(LicensePresentation.deviceCount(used: 1, limit: 5).contains("1"))
        #expect(LicensePresentation.deviceCount(used: 1, limit: 5).contains("5"))
        #expect(LicensePresentation.seatCount(used: 4, limit: 5).contains("4"))
        #expect(LicensePresentation.seatCount(used: 0, limit: 0).isEmpty == false)
    }
}
