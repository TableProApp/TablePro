import Foundation
@testable import TableProMobile
import Testing

@Suite("First run plan")
struct FirstRunPlanTests {
    private func firstRunPlan(
        hasSeenOrigin: Bool = false,
        hasConnections: Bool? = false,
        syncChoice: Bool? = nil,
        usageDataChoice: Bool? = nil,
        iCloudSyncAllowed: Bool = true,
        usageDataAllowed: Bool = true,
        lastSeenVersion: String? = nil,
        currentVersion: String = "1.1",
        hasHighlights: Bool = true
    ) -> FirstRunPlan {
        FirstRunPlan(
            hasSeenOrigin: hasSeenOrigin,
            hasConnections: hasConnections,
            syncChoice: syncChoice,
            usageDataChoice: usageDataChoice,
            iCloudSyncAllowed: iCloudSyncAllowed,
            usageDataAllowed: usageDataAllowed,
            lastSeenVersion: lastSeenVersion,
            currentVersion: currentVersion,
            hasHighlightsForCurrentVersion: hasHighlights
        )
    }

    private func plan(
        hasSeenOrigin: Bool = false,
        hasConnections: Bool? = false,
        syncChoice: Bool? = nil,
        usageDataChoice: Bool? = nil,
        iCloudSyncAllowed: Bool = true,
        usageDataAllowed: Bool = true,
        lastSeenVersion: String? = nil,
        currentVersion: String = "1.1",
        hasHighlights: Bool = true
    ) -> LaunchPresentation {
        firstRunPlan(
            hasSeenOrigin: hasSeenOrigin,
            hasConnections: hasConnections,
            syncChoice: syncChoice,
            usageDataChoice: usageDataChoice,
            iCloudSyncAllowed: iCloudSyncAllowed,
            usageDataAllowed: usageDataAllowed,
            lastSeenVersion: lastSeenVersion,
            currentVersion: currentVersion,
            hasHighlights: hasHighlights
        ).presentation
    }

    // Changed on purpose: the origin page replaces the welcome page.
    @Test("A fresh install asks every question, the origin first")
    func freshInstall() {
        #expect(plan() == .firstRun([.origin, .iCloud, .usageData]))
    }

    @Test("A question the organization's managed configuration answers is not asked")
    func managedQuestionsAreSkipped() {
        #expect(plan(iCloudSyncAllowed: false) == .firstRun([.origin, .usageData]))
        #expect(plan(usageDataAllowed: false) == .firstRun([.origin, .iCloud]))
        #expect(plan(hasSeenOrigin: true, syncChoice: true, usageDataAllowed: false) == .none)
    }

    @Test("A fresh install never shows What's New")
    func freshInstallSkipsWhatsNew() {
        #expect(plan(lastSeenVersion: nil) == .firstRun([.origin, .iCloud, .usageData]))
    }

    @Test("A TestFlight user who finished the old onboarding is asked about usage data only")
    func legacyUserAskedOnce() {
        #expect(plan(hasSeenOrigin: true, syncChoice: true, usageDataChoice: nil) == .firstRun([.usageData]))
    }

    @Test("The iCloud page belongs to the first run and is never shown on its own later")
    func iCloudOnlyWithFirstRun() {
        #expect(plan(hasSeenOrigin: true, syncChoice: nil, usageDataChoice: false) == .none)
    }

    @Test("A sync choice already made keeps the iCloud page out")
    func answeredSyncSkipsPage() {
        #expect(plan(syncChoice: false, usageDataChoice: true) == .firstRun([.origin]))
    }

    @Test("A library that already holds connections leaves the origin out and still asks the questions")
    func connectionsLeaveOutOrigin() {
        #expect(plan(hasConnections: true) == .firstRun([.iCloud, .usageData]))
        #expect(firstRunPlan(hasConnections: true).leavesOutOriginForConnections)
    }

    @Test("A library that did not load leaves the origin out without answering it")
    func unloadedLibraryLeavesOutOrigin() {
        #expect(plan(hasConnections: nil) == .firstRun([.iCloud, .usageData]))
        #expect(!firstRunPlan(hasConnections: nil).leavesOutOriginForConnections)
    }

    @Test("An empty library shows the origin, which only closing the sheet answers")
    func emptyLibraryShowsOrigin() {
        #expect(!firstRunPlan(hasConnections: false).leavesOutOriginForConnections)
    }

    @Test("A seen origin is never left out on account of connections")
    func seenOriginIsNotGated() {
        #expect(!firstRunPlan(hasSeenOrigin: true, hasConnections: true).leavesOutOriginForConnections)
    }

    @Test("Someone who saw the old welcome and has no connections gets the origin once, without the iCloud page")
    func oldWelcomeWithEmptyLibrary() {
        #expect(plan(syncChoice: true, usageDataChoice: false) == .firstRun([.origin]))
    }

    @Test("An upgrade with highlights shows What's New once everything is answered")
    func upgradeShowsWhatsNew() {
        let presentation = plan(
            hasSeenOrigin: true,
            syncChoice: false,
            usageDataChoice: false,
            lastSeenVersion: "1.0",
            currentVersion: "1.1"
        )
        #expect(presentation == .whatsNew(version: "1.1"))
    }

    @Test("An upgrade without highlights shows nothing")
    func upgradeWithoutHighlights() {
        let presentation = plan(
            hasSeenOrigin: true,
            syncChoice: true,
            usageDataChoice: true,
            lastSeenVersion: "1.0",
            hasHighlights: false
        )
        #expect(presentation == .none)
    }

    @Test("A relaunch of the same version shows nothing")
    func sameVersion() {
        let presentation = plan(
            hasSeenOrigin: true,
            syncChoice: true,
            usageDataChoice: false,
            lastSeenVersion: "1.1",
            currentVersion: "1.1"
        )
        #expect(presentation == .none)
    }

    @Test("A pending question wins over What's New")
    func questionBeatsWhatsNew() {
        let presentation = plan(hasSeenOrigin: true, syncChoice: true, lastSeenVersion: "1.0")
        #expect(presentation == .firstRun([.usageData]))
    }

    @Test("An older version shows nothing")
    func olderVersionShowsNothing() {
        let presentation = plan(
            hasSeenOrigin: true,
            syncChoice: true,
            usageDataChoice: false,
            lastSeenVersion: "1.1",
            currentVersion: "1.0"
        )
        #expect(presentation == .none)
    }

    @Test("Versions compare as numbers, not as text")
    func versionsCompareAsNumbers() {
        let presentation = plan(
            hasSeenOrigin: true,
            syncChoice: true,
            usageDataChoice: false,
            lastSeenVersion: "1.9",
            currentVersion: "1.10"
        )
        #expect(presentation == .whatsNew(version: "1.10"))
    }
}
