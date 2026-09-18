//
//  OperationCompletionPolicyTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("OperationCompletionPolicy")
struct OperationCompletionPolicyTests {
    private let connectionId = UUID()
    private let tabId = UUID()

    private func completion(
        kind: TrackedOperationKind = .query,
        elapsed: Duration = .seconds(60),
        outcome: OperationOutcome = .succeeded(OperationSummary(rowsReturned: 12))
    ) -> OperationCompletion {
        OperationCompletion(
            kind: kind,
            owner: .tab(windowId: nil, tabId: tabId),
            connectionId: connectionId,
            connectionName: "Sales",
            databaseName: "production",
            elapsed: elapsed,
            outcome: outcome
        )
    }

    @Test("Work the user cancelled never notifies, however long it ran")
    func cancelledNeverNotifies() {
        let decision = OperationCompletionPolicy.decide(
            completion: completion(elapsed: .seconds(600), outcome: .cancelled),
            visibility: .offScreen,
            settings: .default
        )
        #expect(decision.notification == nil)
        #expect(decision.marksOwnerUnseen == false)
        #expect(decision.suppression == .cancelled)
    }

    @Test("Work shorter than the threshold never notifies")
    func belowThresholdNeverNotifies() {
        let decision = OperationCompletionPolicy.decide(
            completion: completion(elapsed: .seconds(19)),
            visibility: .offScreen,
            settings: NotificationSettings(thresholdSeconds: 20)
        )
        #expect(decision.suppression == .belowThreshold)
        #expect(decision.notification == nil)
    }

    @Test("Work exactly at the threshold notifies")
    func atThresholdNotifies() {
        let decision = OperationCompletionPolicy.decide(
            completion: completion(elapsed: .seconds(20)),
            visibility: .offScreen,
            settings: NotificationSettings(thresholdSeconds: 20)
        )
        #expect(decision.notification != nil)
    }

    @Test("A result the user is looking at never notifies")
    func visibleResultNeverNotifies() {
        let decision = OperationCompletionPolicy.decide(
            completion: completion(elapsed: .seconds(600)),
            visibility: .onScreen,
            settings: .default
        )
        #expect(decision.suppression == .resultOnScreen)
        #expect(decision.notification == nil)
        #expect(decision.marksOwnerUnseen == false)
    }

    /// The HIG asks for an alert rather than a notification for an error, and the tab already
    /// shows an inline error banner. A failure the user is looking at must stay in the tab.
    @Test("A failure the user is looking at never notifies either")
    func visibleFailureNeverNotifies() {
        let decision = OperationCompletionPolicy.decide(
            completion: completion(elapsed: .seconds(600), outcome: .failed(reason: "boom")),
            visibility: .onScreen,
            settings: .default
        )
        #expect(decision.suppression == .resultOnScreen)
        #expect(decision.notification == nil)
    }

    @Test("Any one of app inactive, window hidden or tab unselected is enough to notify")
    func eachVisibilityAxisCounts() {
        let cases = [
            ResultVisibility(appIsActive: false, ownerWindowIsVisible: true, ownerIsSelectedInWindow: true),
            ResultVisibility(appIsActive: true, ownerWindowIsVisible: false, ownerIsSelectedInWindow: true),
            ResultVisibility(appIsActive: true, ownerWindowIsVisible: true, ownerIsSelectedInWindow: false)
        ]
        for visibility in cases {
            let decision = OperationCompletionPolicy.decide(
                completion: completion(), visibility: visibility, settings: .default
            )
            #expect(decision.notification != nil)
        }
    }

    @Test("A disabled kind still marks the tab but posts nothing")
    func disabledKindStillMarksTheTab() {
        var settings = NotificationSettings()
        settings.setEnabled(false, for: .query)
        let decision = OperationCompletionPolicy.decide(
            completion: completion(), visibility: .offScreen, settings: settings
        )
        #expect(decision.notification == nil)
        #expect(decision.marksOwnerUnseen)
        #expect(decision.suppression == .kindDisabled)
    }

    @Test("Turning notifications off entirely still marks the tab")
    func masterSwitchStillMarksTheTab() {
        let decision = OperationCompletionPolicy.decide(
            completion: completion(),
            visibility: .offScreen,
            settings: NotificationSettings(isEnabled: false)
        )
        #expect(decision.notification == nil)
        #expect(decision.marksOwnerUnseen)
    }

    /// One tab owns its query, its structure changes, its row saves and its fetch-all. Keying the
    /// identifier on the owner alone lets a later completion silently replace an earlier one the
    /// user has not read.
    @Test("Different kinds on one tab get different identifiers")
    func identifierIsScopedByKindAsWellAsOwner() {
        let query = OperationCompletionPolicy.identifier(for: completion(kind: .query))
        let save = OperationCompletionPolicy.identifier(for: completion(kind: .rowSave))
        #expect(query != save)
    }

    @Test("Re-running the same kind on the same tab reuses the identifier so it replaces")
    func rerunReplacesRatherThanStacks() {
        let first = OperationCompletionPolicy.identifier(for: completion(elapsed: .seconds(30)))
        let second = OperationCompletionPolicy.identifier(for: completion(elapsed: .seconds(90)))
        #expect(first == second)
    }

    @Test("Notifications group by connection")
    func threadIdentifierIsTheConnection() {
        let decision = OperationCompletionPolicy.decide(
            completion: completion(), visibility: .offScreen, settings: .default
        )
        #expect(decision.notification?.threadIdentifier == connectionId.uuidString)
    }

    @Test("A failure carries its reason for the Copy Error action, a success carries none")
    func failureCarriesItsReason() {
        let failed = OperationCompletionPolicy.decide(
            completion: completion(outcome: .failed(reason: "relation \"orders\" does not exist")),
            visibility: .offScreen,
            settings: .default
        )
        #expect(failed.notification?.failureReason == "relation \"orders\" does not exist")

        let succeeded = OperationCompletionPolicy.decide(
            completion: completion(), visibility: .offScreen, settings: .default
        )
        #expect(succeeded.notification?.failureReason == nil)
    }

    @Test("An export carries its file so Show in Finder has somewhere to go")
    func exportCarriesItsFile() {
        let url = URL(fileURLWithPath: "/tmp/orders.csv")
        let decision = OperationCompletionPolicy.decide(
            completion: completion(
                kind: .dataExport, outcome: .succeeded(OperationSummary(fileURL: url))
            ),
            visibility: .offScreen,
            settings: .default
        )
        #expect(decision.notification?.revealURL == url)
    }

    @Test("The threshold is clamped, so a nonsense stored value cannot silence or spam")
    func thresholdIsClamped() {
        #expect(NotificationSettings(thresholdSeconds: 0).validatedThresholdSeconds == 5)
        #expect(NotificationSettings(thresholdSeconds: 99_999).validatedThresholdSeconds == 600)
    }

    /// Stored as the kinds that are OFF, so a kind added by a later release arrives enabled
    /// instead of being silently absent from an older stored set.
    @Test("A kind the stored settings have never heard of is enabled")
    func unknownKindDefaultsToEnabled() {
        let settings = NotificationSettings(disabledKindIds: ["somethingOlderBuildsNeverKnew"])
        #expect(settings.isEnabled(for: .backup))
    }

    /// Automatic grammar agreement returns its own markup verbatim when the catalog has no entry
    /// for the key, which put "3 ^[row](inflect: true) in 1m 00s" in a notification body during
    /// development. Nothing about that fails to compile, so it is guarded here instead.
    @Test("A notification body never leaks localization markup")
    func bodyNeverLeaksMarkup() {
        let summaries = [
            OperationSummary(rowsReturned: 3),
            OperationSummary(rowsReturned: 1),
            OperationSummary(rowsAffected: 4_900),
            OperationSummary(rowsAffected: 1),
            OperationSummary(statementCount: 12),
            OperationSummary(statementCount: 1)
        ]
        for summary in summaries {
            let body = OperationCompletionCopy.body(for: completion(outcome: .succeeded(summary)))
            #expect(!body.contains("^["))
            #expect(!body.contains("inflect:"))
            #expect(!body.contains("%lld"))
            #expect(!body.contains("%@"))
        }
    }

    @Test("Counts read naturally in the singular and the plural")
    func countsAgreeWithTheirNumber() {
        func body(_ summary: OperationSummary) -> String {
            OperationCompletionCopy.body(for: completion(outcome: .succeeded(summary)))
        }
        #expect(body(OperationSummary(rowsReturned: 1)) == "1 row in 1m 00s")
        #expect(body(OperationSummary(rowsReturned: 1_204)) == "\(Self.grouped(1_204)) rows in 1m 00s")
        #expect(body(OperationSummary(rowsAffected: 1)) == "Updated 1 row in 1m 00s")
        #expect(body(OperationSummary(statementCount: 1)) == "Ran 1 statement in 1m 00s")
        #expect(body(OperationSummary(statementCount: 12)) == "Ran 12 statements in 1m 00s")
    }

    /// Several drivers echo the returned row count back as the affected count for a plain read
    /// (MySQL does it in two places), so testing affected first told the user their SELECT had
    /// updated 1,204 rows.
    @Test("A read that echoes its row count as an affected count still reads as a read")
    func returnedRowsWinOverAnEchoedAffectedCount() {
        let echoed = OperationSummary(rowsReturned: 1_204, rowsAffected: 1_204)
        let body = OperationCompletionCopy.body(for: completion(outcome: .succeeded(echoed)))
        #expect(body == "\(Self.grouped(1_204)) rows in 1m 00s")
        #expect(!body.contains("Updated"))
    }

    @Test("A write with no result set still reads as a write")
    func writesStillReportAsUpdates() {
        let write = OperationSummary(rowsReturned: 0, rowsAffected: 4_900)
        let body = OperationCompletionCopy.body(for: completion(outcome: .succeeded(write)))
        #expect(body == "Updated \(Self.grouped(4_900)) rows in 1m 00s")
    }

    /// The mark means "finished somewhere you were not looking". A tab the user already has
    /// selected is not that, and marking it left a dot no path could clear: the clear paths are
    /// keyed on a tab change, and coming back to the app is not one.
    @Test("A tab the user already has selected is never marked unseen")
    func selectedTabIsNeverMarkedUnseen() {
        let awayButSelected = ResultVisibility(
            appIsActive: false, ownerWindowIsVisible: true, ownerIsSelectedInWindow: true
        )
        let decision = OperationCompletionPolicy.decide(
            completion: completion(), visibility: awayButSelected, settings: .default
        )
        #expect(decision.notification != nil)
        #expect(!decision.marksOwnerUnseen)
    }

    /// A category's actions are fixed when it is registered, so the category has to carry the
    /// outcome. Sharing one meant every success notification showed a Copy Error button that did
    /// nothing.
    @Test("Each outcome picks the category whose actions actually apply")
    func categoryMatchesTheActionsThatApply() {
        #expect(
            OperationCompletionPolicy.categoryId(for: .failed(reason: "x"))
                == OperationCompletionPolicy.Category.failed
        )
        #expect(
            OperationCompletionPolicy.categoryId(for: .succeeded(OperationSummary(rowsReturned: 1)))
                == OperationCompletionPolicy.Category.plain
        )
        #expect(
            OperationCompletionPolicy.categoryId(
                for: .succeeded(OperationSummary(fileURL: URL(fileURLWithPath: "/tmp/a.csv")))
            ) == OperationCompletionPolicy.Category.producedFile
        )
    }

    /// Counts are grouped in the reader's own locale, so the separator is a comma on this machine
    /// and a period on the next one. Asserting a literal "1,204" passes wherever the developer
    /// happens to live and fails on a runner set to anything else, which is a test about the
    /// machine rather than about the code.
    private static func grouped(_ count: Int) -> String {
        count.formatted(.number.grouping(.automatic))
    }

    @Test("Large counts are grouped for the reader's locale rather than run together")
    func largeCountsAreGrouped() {
        #expect(Self.grouped(1_204) != "1204")
    }
}
