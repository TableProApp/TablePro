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
        let notice = LicensePresentation.notice(status: .active, daysUntilExpiry: 90, isExpired: false, hasLicense: true)
        #expect(notice == nil)
    }

    @Test("A lifetime license never warns about expiry")
    func lifetimeLicenseHasNoNotice() {
        let notice = LicensePresentation.notice(status: .active, daysUntilExpiry: nil, isExpired: false, hasLicense: true)
        #expect(notice == nil)
    }

    @Test("Expiry is raised inside the last week and not before")
    func expiryWarningWindow() {
        let eightDays = LicensePresentation.notice(status: .active, daysUntilExpiry: 8, isExpired: false, hasLicense: true)
        #expect(eightDays == nil)

        let sevenDays = LicensePresentation.notice(status: .active, daysUntilExpiry: 7, isExpired: false, hasLicense: true)
        #expect(sevenDays?.action == .renew)
        #expect(sevenDays?.tone == .informational)

        let today = LicensePresentation.notice(status: .active, daysUntilExpiry: 0, isExpired: false, hasLicense: true)
        #expect(today?.action == .renew)
    }

    /// `daysUntilExpiry` counts whole days, so a license that ran out this morning still reports
    /// zero. Without the expiry guard the notice read "expires in 0 days" for a license the pane
    /// was simultaneously reporting as expired.
    @Test("A license that already lapsed is not warned about as expiring soon")
    func lapsedLicenseIsNotExpiringSoon() {
        let notice = LicensePresentation.notice(
            status: .active,
            daysUntilExpiry: 0,
            isExpired: true,
            hasLicense: true
        )
        #expect(notice == nil)
    }

    @Test("An expired license offers renewal")
    func expiredOffersRenewal() {
        let notice = LicensePresentation.notice(status: .expired, daysUntilExpiry: -3, isExpired: true, hasLicense: true)
        #expect(notice?.action == .renew)
        #expect(notice?.tone == .warning, "Renew is a way out, so this is not critical")
    }

    @Test("A suspended license offers no self-service action")
    func suspendedOffersNoAction() {
        let notice = LicensePresentation.notice(status: .suspended, daysUntilExpiry: nil, isExpired: false, hasLicense: true)
        #expect(notice?.action == nil)
        #expect(notice?.tone == .critical)
    }

    @Test("A license that ran out of offline grace offers to try the server again")
    func validationFailedOffersRetry() {
        let notice = LicensePresentation.notice(status: .validationFailed, daysUntilExpiry: nil, isExpired: false, hasLicense: true)
        #expect(notice?.action == .retryValidation)
    }

    @Test("A Mac whose seat was given up is told so, rather than looking like it never had one")
    func deactivatedIsDistinctFromUnlicensed() {
        let deactivated = LicensePresentation.notice(status: .deactivated, daysUntilExpiry: nil, isExpired: false, hasLicense: false)
        #expect(deactivated != nil, "Giving up a seat here is worth saying")
        #expect(deactivated?.action == nil, "The landing field below it is already the way back in")

        let neverLicensed = LicensePresentation.notice(status: .unlicensed, daysUntilExpiry: nil, isExpired: false, hasLicense: false)
        #expect(neverLicensed == nil, "Somebody who never bought a license is not in a degraded state")
    }

    @Test("A key the server no longer knows is reported rather than silently blank")
    func unlicensedWithARecordIsReported() {
        let notice = LicensePresentation.notice(status: .unlicensed, daysUntilExpiry: nil, isExpired: false, hasLicense: true)
        #expect(notice?.action == .purchase)
    }

    @Test("Every status resolves without trapping")
    func everyStatusIsCovered() {
        let all: [LicenseStatus] = [.unlicensed, .active, .expired, .suspended, .deactivated, .validationFailed]
        for status in all {
            for hasLicense in [true, false] {
                _ = LicensePresentation.notice(
                    status: status,
                    daysUntilExpiry: 3,
                    isExpired: false,
                    hasLicense: hasLicense
                )
            }
        }
    }

    // MARK: - Tone follows what the reader can do

    /// Reserved for a state with no way out. An expired licence offers Renew and an unrecognised
    /// one offers a purchase, so painting either red overstates them.
    @Test("Only a state offering no action is critical")
    func criticalIsReservedForADeadEnd() {
        let suspended = LicensePresentation.notice(
            status: .suspended, daysUntilExpiry: nil, isExpired: false, hasLicense: true
        )
        #expect(suspended?.tone == .critical)
        #expect(suspended?.action == nil)

        for status in [LicenseStatus.expired, .validationFailed, .unlicensed] {
            let notice = LicensePresentation.notice(
                status: status, daysUntilExpiry: -1, isExpired: status == .expired, hasLicense: true
            )
            #expect(notice?.tone != .critical, "\(status.rawValue) offers a way out")
            #expect(notice?.action != nil)
        }
    }

    // MARK: - Which states ask for a key

    /// A licence the server has not confirmed in 30 days is one its owner already holds, so asking
    /// for a key needs the very network the state is defined by lacking.
    @Test("An unverified license is not asked for a new key; an expired one is")
    func renewalFieldOnlyWhereAKeyHelps() {
        #expect(LicensePresentation.showsRenewalField(status: .expired))
        #expect(LicensePresentation.showsRenewalField(status: .unlicensed))
        #expect(LicensePresentation.showsRenewalField(status: .validationFailed) == false)
        #expect(LicensePresentation.showsRenewalField(status: .active) == false)
    }

    // MARK: - Expiry wording

    @Test("The last two days are named, not counted")
    func expiryNamesTodayAndTomorrow() {
        let today = LicensePresentation.notice(status: .active, daysUntilExpiry: 0, isExpired: false, hasLicense: true)
        #expect(today?.message.contains("0") == false, "\"in 0 days\" is not something to ship")

        let tomorrow = LicensePresentation.notice(status: .active, daysUntilExpiry: 1, isExpired: false, hasLicense: true)
        #expect(tomorrow?.message.contains("1 days") == false, "\"in 1 days\" is not grammatical")

        let later = LicensePresentation.notice(status: .active, daysUntilExpiry: 5, isExpired: false, hasLicense: true)
        #expect(later?.message.contains("5") == true)
    }

    // MARK: - Plan line

    /// Shipped as "Team · Lifetime · Lifetime": the billing cycle is already the word, and the
    /// absent expiry said it a second time.
    @Test("A lifetime license says lifetime once")
    func lifetimePlanSaysItOnce() {
        let line = LicensePresentation.planDescription(tier: "team", billingCycle: "lifetime", expiry: nil)
        #expect(line.components(separatedBy: "Lifetime").count - 1 == 1, "Got: \(line)")
    }

    @Test("A recurring license states its cycle and its expiry")
    func recurringPlanStatesBoth() {
        let line = LicensePresentation.planDescription(
            tier: "starter", billingCycle: "yearly", expiry: "12 Mar 2027"
        )
        #expect(line.contains("Yearly"))
        #expect(line.contains("12 Mar 2027"))
    }

    @Test("A license with no billing cycle still reads cleanly")
    func planWithoutCycle() {
        let line = LicensePresentation.planDescription(tier: "starter", billingCycle: nil, expiry: "1 Jan 2030")
        #expect(line.hasPrefix("Starter"))
        #expect(line.contains(" ·  · ") == false, "No empty segment")
    }

    // MARK: - Key masking

    @Test("A key shows its first group only, so a screen share never carries the whole credential")
    func maskedKeyKeepsOnlyTheFirstGroup() {
        let masked = LicensePresentation.maskedKey("ABCDE-FGHIJ-KLMNO-PQRST-UVWXY")
        #expect(masked == "ABCDE…")
        for group in ["FGHIJ", "KLMNO", "PQRST", "UVWXY"] {
            #expect(masked.contains(group) == false)
        }
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
        #expect(LicensePresentation.memberCount(used: 4, limit: 5).contains("4"))
        #expect(LicensePresentation.memberCount(used: 0, limit: 0).isEmpty == false)
    }
}
