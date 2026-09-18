import Foundation
@testable import TableProMobile
import Testing

@Suite("First run plan")
struct FirstRunPlanTests {
    private func plan(
        hasSeenWelcome: Bool = false,
        syncChoice: Bool? = nil,
        usageDataChoice: Bool? = nil,
        lastSeenVersion: String? = nil,
        currentVersion: String = "1.1",
        hasHighlights: Bool = true
    ) -> LaunchPresentation {
        FirstRunPlan(
            hasSeenWelcome: hasSeenWelcome,
            syncChoice: syncChoice,
            usageDataChoice: usageDataChoice,
            lastSeenVersion: lastSeenVersion,
            currentVersion: currentVersion,
            hasHighlightsForCurrentVersion: hasHighlights
        ).presentation
    }

    @Test("A fresh install asks every question, welcome first")
    func freshInstall() {
        #expect(plan() == .firstRun([.welcome, .iCloud, .usageData]))
    }

    @Test("A fresh install never shows What's New")
    func freshInstallSkipsWhatsNew() {
        #expect(plan(lastSeenVersion: nil) == .firstRun([.welcome, .iCloud, .usageData]))
    }

    @Test("A TestFlight user who finished the old onboarding is asked about usage data only")
    func legacyUserAskedOnce() {
        #expect(plan(hasSeenWelcome: true, syncChoice: true, usageDataChoice: nil) == .firstRun([.usageData]))
    }

    @Test("The iCloud page belongs to the welcome and is never shown on its own later")
    func iCloudOnlyWithWelcome() {
        #expect(plan(hasSeenWelcome: true, syncChoice: nil, usageDataChoice: false) == .none)
    }

    @Test("A sync choice already made keeps the iCloud page out of the welcome")
    func answeredSyncSkipsPage() {
        #expect(plan(syncChoice: false, usageDataChoice: true) == .firstRun([.welcome]))
    }

    @Test("An upgrade with highlights shows What's New once everything is answered")
    func upgradeShowsWhatsNew() {
        let presentation = plan(
            hasSeenWelcome: true,
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
            hasSeenWelcome: true,
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
            hasSeenWelcome: true,
            syncChoice: true,
            usageDataChoice: false,
            lastSeenVersion: "1.1",
            currentVersion: "1.1"
        )
        #expect(presentation == .none)
    }

    @Test("A pending question wins over What's New")
    func questionBeatsWhatsNew() {
        let presentation = plan(hasSeenWelcome: true, syncChoice: true, lastSeenVersion: "1.0")
        #expect(presentation == .firstRun([.usageData]))
    }
}
