import Foundation
@testable import TableProMobile
import Testing

@Suite("First run plan")
struct FirstRunPlanTests {
    private func plan(
        hasSeenWelcome: Bool = false,
        syncChoice: Bool? = nil,
        lastSeenVersion: String? = nil,
        currentVersion: String = "1.1",
        hasHighlights: Bool = true
    ) -> LaunchPresentation {
        FirstRunPlan(
            hasSeenWelcome: hasSeenWelcome,
            syncChoice: syncChoice,
            lastSeenVersion: lastSeenVersion,
            currentVersion: currentVersion,
            hasHighlightsForCurrentVersion: hasHighlights
        ).presentation
    }

    @Test("A fresh install shows the welcome, then the iCloud question, and asks nothing about usage data")
    func freshInstall() {
        #expect(plan() == .firstRun([.welcome, .iCloud]))
    }

    @Test("A fresh install never shows What's New")
    func freshInstallSkipsWhatsNew() {
        #expect(plan(lastSeenVersion: nil) == .firstRun([.welcome, .iCloud]))
    }

    @Test("A user who saw the welcome before usage data had a default is not asked about it")
    func unansweredUsageDataAsksNothing() {
        #expect(plan(hasSeenWelcome: true, syncChoice: true) == .none)
    }

    @Test("The iCloud page belongs to the welcome and is never shown on its own later")
    func iCloudOnlyWithWelcome() {
        #expect(plan(hasSeenWelcome: true, syncChoice: nil) == .none)
    }

    @Test("A sync choice already made keeps the iCloud page out of the welcome")
    func answeredSyncSkipsPage() {
        #expect(plan(syncChoice: false) == .firstRun([.welcome]))
    }

    @Test("An upgrade with highlights shows What's New once everything is answered")
    func upgradeShowsWhatsNew() {
        let presentation = plan(
            hasSeenWelcome: true,
            syncChoice: false,
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
            lastSeenVersion: "1.1",
            currentVersion: "1.1"
        )
        #expect(presentation == .none)
    }

    @Test("The welcome wins over What's New")
    func welcomeBeatsWhatsNew() {
        let presentation = plan(syncChoice: true, lastSeenVersion: "1.0")
        #expect(presentation == .firstRun([.welcome]))
    }

    @Test("An older version shows nothing")
    func olderVersionShowsNothing() {
        let presentation = plan(
            hasSeenWelcome: true,
            syncChoice: true,
            lastSeenVersion: "1.1",
            currentVersion: "1.0"
        )
        #expect(presentation == .none)
    }

    @Test("Versions compare as numbers, not as text")
    func versionsCompareAsNumbers() {
        let presentation = plan(
            hasSeenWelcome: true,
            syncChoice: true,
            lastSeenVersion: "1.9",
            currentVersion: "1.10"
        )
        #expect(presentation == .whatsNew(version: "1.10"))
    }
}
