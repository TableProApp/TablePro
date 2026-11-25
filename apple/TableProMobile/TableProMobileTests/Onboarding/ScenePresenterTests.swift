import Foundation
import TableProImport
@testable import TableProMobile
import Testing

@MainActor
@Suite("Scene presenter")
struct ScenePresenterTests {
    private let connectionId = UUID()

    @Test("An incoming link waits while any sheet is open, then arrives")
    func waitsForSheet() {
        let presenter = ScenePresenter()
        presenter.present(.addConnection)
        presenter.receive(.openConnection(connectionId, table: nil))

        #expect(presenter.takeDeliverableIntent(isLocked: false, isLibraryWritable: true) == nil)

        presenter.sheet = nil
        #expect(presenter.takeDeliverableIntent(isLocked: false, isLibraryWritable: true) == .openConnection(connectionId, table: nil))
        #expect(presenter.takeDeliverableIntent(isLocked: false, isLibraryWritable: true) == nil)
    }

    @Test("Nothing is delivered while the app is locked")
    func waitsForUnlock() {
        let presenter = ScenePresenter(isLockedAtLaunch: true)
        presenter.receive(.openConnection(connectionId, table: nil))

        #expect(presenter.takeDeliverableIntent(isLocked: true, isLibraryWritable: true) == nil)

        presenter.lockDidChange(false)
        #expect(presenter.takeDeliverableIntent(isLocked: false, isLibraryWritable: true) != nil)
    }

    @Test("A lock that arrives with the link refuses it, whatever the hold has already done")
    func lockWinsOverTheReleasedHold() {
        let presenter = ScenePresenter(isLockedAtLaunch: true)
        presenter.lockDidChange(false)
        #expect(presenter.holdsConnectionRestore == false)

        presenter.receive(.openConnection(connectionId, table: nil))
        #expect(presenter.takeDeliverableIntent(isLocked: true, isLibraryWritable: true) == nil)

        #expect(presenter.takeDeliverableIntent(isLocked: false, isLibraryWritable: true) != nil)
    }

    @Test("A presenter born locked holds the connection restore until the first unlock")
    func lockedLaunchHoldsRestore() {
        let presenter = ScenePresenter(isLockedAtLaunch: true)

        #expect(presenter.restoreHolds == [.appLock])
        #expect(presenter.holdsConnectionRestore)

        presenter.lockDidChange(false)
        #expect(presenter.holdsConnectionRestore == false)
    }

    @Test("A later lock never takes the restore hold back")
    func idleLockDoesNotRetakeTheHold() {
        let presenter = ScenePresenter(isLockedAtLaunch: true)
        presenter.lockDidChange(false)

        presenter.lockDidChange(true)
        #expect(presenter.holdsConnectionRestore == false)
    }

    @Test("A presenter born unlocked never takes the restore hold")
    func unlockedLaunchNeverHolds() {
        let presenter = ScenePresenter()
        #expect(presenter.holdsConnectionRestore == false)

        presenter.lockDidChange(true)
        #expect(presenter.holdsConnectionRestore == false)
    }

    // Changed on purpose: the origin page replaces the welcome page.
    @Test("Dismissing the launch sheet leaves the lock hold standing")
    func launchSheetDismissalKeepsTheLockHold() throws {
        let fixture = try AppStateFixture()
        let appState = fixture.makeState(syncEnabled: false)
        let presenter = ScenePresenter(isLockedAtLaunch: true)
        presenter.present(.firstRun([.origin]))

        presenter.sheet = nil
        presenter.sheetDidDismiss(appState: appState)
        #expect(presenter.restoreHolds == [.appLock])
        #expect(presenter.holdsConnectionRestore)

        presenter.lockDidChange(false)
        #expect(presenter.holdsConnectionRestore == false)
    }

    @Test("The action chosen on the origin page is handed over once the first run has closed, and only once")
    func startActionHandedOverAfterClose() throws {
        let fixture = try AppStateFixture()
        let appState = fixture.makeState(syncEnabled: false)
        let presenter = ScenePresenter()
        presenter.present(.firstRun([.origin, .usageData]))
        presenter.recordStartAction(.addConnection)

        #expect(presenter.sheetDidDismiss(appState: appState) == nil)

        presenter.sheet = nil
        #expect(presenter.sheetDidDismiss(appState: appState) == .addConnection)
        #expect(presenter.sheetDidDismiss(appState: appState) == nil)
    }

    @Test("Skipping the origin page hands over nothing")
    func skippedOriginHandsOverNothing() throws {
        let fixture = try AppStateFixture()
        let appState = fixture.makeState(syncEnabled: false)
        let presenter = ScenePresenter()
        presenter.present(.firstRun([.origin]))

        presenter.sheet = nil
        #expect(presenter.sheetDidDismiss(appState: appState) == nil)
    }

    @Test("A file the app was opened with wins over the action chosen on the origin page")
    func pendingFileWinsOverStartAction() throws {
        let fixture = try AppStateFixture()
        let appState = fixture.makeState(syncEnabled: false)
        let presenter = ScenePresenter()
        let file = URL(fileURLWithPath: "/tmp/Team.tablepro")
        presenter.present(.firstRun([.origin]))
        presenter.recordStartAction(.openSample)
        presenter.receive(.importConnections(file))

        presenter.sheet = nil
        #expect(presenter.sheetDidDismiss(appState: appState) == nil)
        #expect(presenter.takeDeliverableIntent(isLocked: false, isLibraryWritable: true) == .importConnections(file))
    }

    @Test("A link delivered after the reopened guide clears and before it dismisses still wins over its start action")
    func linkDeliveredDuringReopenedGuideDismissal() throws {
        let fixture = try AppStateFixture()
        let appState = fixture.makeState(syncEnabled: false)
        let presenter = ScenePresenter()
        let file = URL(fileURLWithPath: "/tmp/Team.tablepro")
        presenter.presentSetupGuide()
        presenter.recordStartAction(.openSample)

        presenter.sheet = nil
        presenter.receive(.importConnections(file))
        #expect(presenter.takeDeliverableIntent(isLocked: false, isLibraryWritable: true) == .importConnections(file))
        #expect(presenter.sheetDidDismiss(appState: appState) == nil)
    }

    @Test("Closing a sheet that is not the first run hands over nothing")
    func otherSheetHandsOverNothing() throws {
        let fixture = try AppStateFixture()
        let appState = fixture.makeState(syncEnabled: false)
        let presenter = ScenePresenter()
        presenter.present(.settings)
        presenter.recordStartAction(.addConnection)

        presenter.sheet = nil
        #expect(presenter.sheetDidDismiss(appState: appState) == nil)
    }

    @Test("A saved connection is handed over once its sheet has gone, and only once")
    func savedConnectionHandedOverAfterSheet() {
        let presenter = ScenePresenter()
        presenter.present(.addConnection)
        presenter.openAfterSheet(connectionId)

        presenter.sheet = nil
        #expect(presenter.takeHandoffAfterSheet() == .open(connectionId))
        #expect(presenter.takeHandoffAfterSheet() == nil)
    }

    @Test("A link that came in while the sheet was up wins over opening the saved connection")
    func pendingLinkWinsOverSavedConnection() {
        let presenter = ScenePresenter()
        let linked = UUID()
        presenter.present(.addConnection)
        presenter.receive(.openConnection(linked, table: nil))
        presenter.openAfterSheet(connectionId)

        presenter.sheet = nil
        #expect(presenter.takeHandoffAfterSheet() == nil)
        #expect(presenter.takeDeliverableIntent(isLocked: false, isLibraryWritable: true) == .openConnection(linked, table: nil))
    }

    @Test("A file delivered before the sheet's dismissal still keeps the saved connection from opening")
    func deliveredFileWinsOverSavedConnection() {
        let presenter = ScenePresenter()
        let file = URL(fileURLWithPath: "/tmp/Team.tablepro")
        presenter.present(.importFile(file))
        presenter.openAfterSheet(connectionId)

        presenter.sheet = nil
        presenter.receive(.importConnections(file))
        #expect(presenter.takeDeliverableIntent(isLocked: false, isLibraryWritable: true) == .importConnections(file))
        #expect(presenter.takeHandoffAfterSheet() == nil)
    }

    @Test("A connections file of one connection reveals it and reports, never opens it")
    func singleFileImportReveals() {
        let presenter = ScenePresenter()
        let outcome = ImportOutcome(connectionIds: [connectionId], connectionsAdded: 1)
        presenter.present(.importFile(URL(fileURLWithPath: "/tmp/Team.tablepro")))

        #expect(presenter.finishImport(outcome, from: .fileOrLink) == MobileImportOutcomeMessage(outcome))

        presenter.sheet = nil
        #expect(presenter.takeHandoffAfterSheet() == .reveal([connectionId]))
        #expect(presenter.takeHandoffAfterSheet() == nil)
    }

    @Test("A single clean import from the user's own machine or account opens its connection, with no message")
    func singleOwnImportOpens() {
        let presenter = ScenePresenter()
        let outcome = ImportOutcome(connectionIds: [connectionId], connectionsAdded: 1)

        #expect(presenter.finishImport(outcome, from: .ownMachineOrAccount) == nil)
        #expect(presenter.takeHandoffAfterSheet() == .open(connectionId))
    }

    @Test("A batch import reveals every connection it wrote once the sheet has gone, and keeps its count message")
    func batchImportReveals() {
        let presenter = ScenePresenter()
        let other = UUID()
        let outcome = ImportOutcome(connectionIds: [connectionId, other], connectionsAdded: 1, connectionsReplaced: 1)
        presenter.present(.importFile(URL(fileURLWithPath: "/tmp/Team.tablepro")))

        #expect(presenter.finishImport(outcome, from: .fileOrLink) == MobileImportOutcomeMessage(outcome))

        presenter.sheet = nil
        #expect(presenter.takeHandoffAfterSheet() == .reveal([connectionId, other]))
        #expect(presenter.takeHandoffAfterSheet() == nil)
    }

    @Test("A single import that lost a password is revealed and reported instead of opened")
    func singleImportWithLossReveals() {
        let presenter = ScenePresenter()
        let outcome = ImportOutcome(connectionIds: [connectionId], connectionsAdded: 1, passwordsNotKept: 1)

        #expect(presenter.finishImport(outcome, from: .ownMachineOrAccount) == MobileImportOutcomeMessage(outcome))
        #expect(presenter.takeHandoffAfterSheet() == .reveal([connectionId]))
    }

    @Test("An import that wrote no connection reports and hands nothing over")
    func emptyImportStays() {
        let presenter = ScenePresenter()
        let outcome = ImportOutcome(savedQueriesAdded: 2)
        presenter.present(.importFile(URL(fileURLWithPath: "/tmp/Team.tablepro")))

        #expect(presenter.finishImport(outcome, from: .fileOrLink) == MobileImportOutcomeMessage(outcome))

        presenter.sheet = nil
        #expect(presenter.takeHandoffAfterSheet() == nil)
    }

    @Test("A link that came in while the import sheet was up wins over revealing the batch")
    func pendingLinkSkipsReveal() {
        let presenter = ScenePresenter()
        let linked = UUID()
        presenter.present(.importFile(URL(fileURLWithPath: "/tmp/Team.tablepro")))
        presenter.receive(.openConnection(linked, table: nil))
        _ = presenter.finishImport(ImportOutcome(connectionIds: [connectionId, UUID()], connectionsAdded: 2), from: .fileOrLink)

        presenter.sheet = nil
        #expect(presenter.takeHandoffAfterSheet() == nil)
        #expect(presenter.takeDeliverableIntent(isLocked: false, isLibraryWritable: true) == .openConnection(linked, table: nil))
    }

    @Test("The setup guide shows the origin page alone and marks it seen when it closes")
    func setupGuideShowsOriginAgain() throws {
        let fixture = try AppStateFixture()
        let appState = fixture.makeState(syncEnabled: false)
        let presenter = ScenePresenter()

        presenter.presentSetupGuide()
        guard case .firstRun(let pages)? = presenter.sheet else {
            Issue.record("The setup guide did not open the first run sheet")
            return
        }
        #expect(pages == [.origin])

        presenter.recordStartAction(.importConnections)
        presenter.sheet = nil
        #expect(presenter.sheetDidDismiss(appState: appState) == .importConnections)
        #expect(appState.onboarding.hasSeenOrigin)
    }

    @Test("A link waiting to be delivered holds the connection restore, and lets go with the delivery")
    func pendingIntentHoldsRestore() {
        let presenter = ScenePresenter()
        presenter.receive(.openConnection(connectionId, table: nil))

        #expect(presenter.restoreHolds == [.pendingIntent])
        #expect(presenter.holdsConnectionRestore)

        #expect(presenter.takeDeliverableIntent(isLocked: false, isLibraryWritable: true) != nil)
        #expect(presenter.holdsConnectionRestore == false)
    }

    @Test("A link an undelivered import holds back still keeps the restore waiting")
    func undeliverableImportKeepsTheHold() {
        let presenter = ScenePresenter()
        presenter.receive(.importConnections(URL(fileURLWithPath: "/tmp/Team.tablepro")))

        #expect(presenter.takeDeliverableIntent(isLocked: false, isLibraryWritable: false) == nil)
        #expect(presenter.restoreHolds == [.pendingIntent])
    }

    @Test("The link's own hold never blocks the link, and every other hold still does")
    func ownHoldDoesNotBlockDelivery() {
        let presenter = ScenePresenter(isLockedAtLaunch: true)
        presenter.receive(.importConnections(URL(fileURLWithPath: "/tmp/Team.tablepro")))

        #expect(presenter.restoreHolds == [.appLock, .pendingIntent])
        #expect(presenter.takeDeliverableIntent(isLocked: false, isLibraryWritable: true) == nil)

        presenter.lockDidChange(false)
        #expect(presenter.takeDeliverableIntent(isLocked: false, isLibraryWritable: true) != nil)
        #expect(presenter.restoreHolds.isEmpty)
    }

    @Test("A restore hold postpones a connection that is not open, and never closes one that is")
    func holdNeverClosesAnOpenConnection() {
        let presenter = ScenePresenter(isLockedAtLaunch: true)

        #expect(presenter.presentsConnectionCover(isOnScreen: false) == false)
        #expect(presenter.presentsConnectionCover(isOnScreen: true))

        presenter.lockDidChange(false)
        #expect(presenter.presentsConnectionCover(isOnScreen: false))
    }

    @Test("A file that arrives with no cover on screen is presented at once")
    func importWithoutCoverIsPresentedAtOnce() {
        let presenter = ScenePresenter()
        let file = URL(fileURLWithPath: "/tmp/Team.tablepro")

        presenter.presentImportFile(file, coverIsOnScreen: false)
        #expect(presenter.sheet?.id == SceneSheet.importFile(file).id)
        #expect(presenter.heldImportFile == nil)
    }

    @Test("A file that arrives over an open connection is presented once, when the cover dismisses")
    func importOverACoverWaitsForTheDismissal() {
        let presenter = ScenePresenter()
        let file = URL(fileURLWithPath: "/tmp/Team.tablepro")

        presenter.presentImportFile(file, coverIsOnScreen: true)
        #expect(presenter.sheet == nil)
        #expect(presenter.heldImportFile == file)

        presenter.presentHeldImport()
        #expect(presenter.sheet?.id == SceneSheet.importFile(file).id)
        #expect(presenter.heldImportFile == nil)

        presenter.sheet = nil
        presenter.presentHeldImport()
        #expect(presenter.sheet == nil)
    }

    @Test("A refusal with no cover on screen is presented at once")
    func refusalWithoutCoverIsPresentedAtOnce() {
        let presenter = ScenePresenter()

        presenter.presentRefusal(for: connectionId, coverIsOnScreen: false)
        #expect(presenter.refusedConnectionId == connectionId)
        #expect(presenter.heldRefusalId == nil)
    }

    @Test("A refusal that arrives over an open connection is presented once, when the cover dismisses")
    func refusalOverACoverWaitsForTheDismissal() {
        let presenter = ScenePresenter()

        presenter.presentRefusal(for: connectionId, coverIsOnScreen: true)
        #expect(presenter.refusedConnectionId == nil)
        #expect(presenter.heldRefusalId == connectionId)

        presenter.presentHeldRefusal()
        #expect(presenter.refusedConnectionId == connectionId)
        #expect(presenter.heldRefusalId == nil)

        presenter.refusedConnectionId = nil
        presenter.presentHeldRefusal()
        #expect(presenter.refusedConnectionId == nil)
    }

    @Test("An import waits until the stored library can be written")
    func importWaitsForLibrary() {
        let presenter = ScenePresenter()
        let file = URL(fileURLWithPath: "/tmp/Team.tablepro")
        presenter.receive(.importConnections(file))

        #expect(presenter.takeDeliverableIntent(isLocked: false, isLibraryWritable: false) == nil)
        #expect(presenter.takeDeliverableIntent(isLocked: false, isLibraryWritable: true) == .importConnections(file))
    }

    @Test("The latest link wins")
    func latestWins() {
        let presenter = ScenePresenter()
        let other = UUID()
        presenter.receive(.openConnection(connectionId, table: nil))
        presenter.receive(.openConnection(other, table: "users"))

        #expect(presenter.takeDeliverableIntent(isLocked: false, isLibraryWritable: true) == .openConnection(other, table: "users"))
    }

    @Test("A requested table is taken once, and only by its own connection")
    func tableRequest() {
        let presenter = ScenePresenter()
        presenter.requestTable("Track", in: connectionId)

        #expect(presenter.takeTable(for: UUID()) == nil)
        #expect(presenter.takeTable(for: connectionId) == "Track")
        #expect(presenter.takeTable(for: connectionId) == nil)
    }

    @Test("A link waits while an editor holds unsaved changes, then arrives")
    func waitsForEditor() {
        let presenter = ScenePresenter()
        let editor = UUID()
        presenter.setEditorHold(editor, isHolding: true)
        presenter.receive(.openConnection(connectionId, table: nil))

        #expect(presenter.isHeldByEditor)
        #expect(presenter.takeDeliverableIntent(isLocked: false, isLibraryWritable: true) == nil)

        presenter.setEditorHold(editor, isHolding: false)
        #expect(presenter.isHeldByEditor == false)
        #expect(presenter.takeDeliverableIntent(isLocked: false, isLibraryWritable: true) == .openConnection(connectionId, table: nil))
    }

    @Test("Every editor has to let go before a link arrives")
    func waitsForEveryEditor() {
        let presenter = ScenePresenter()
        let first = UUID()
        let second = UUID()
        presenter.setEditorHold(first, isHolding: true)
        presenter.setEditorHold(second, isHolding: true)
        presenter.receive(.openConnection(connectionId, table: nil))

        presenter.setEditorHold(first, isHolding: false)
        #expect(presenter.takeDeliverableIntent(isLocked: false, isLibraryWritable: true) == nil)

        presenter.setEditorHold(second, isHolding: false)
        #expect(presenter.takeDeliverableIntent(isLocked: false, isLibraryWritable: true) != nil)
    }

    @Test("An opened data file waits for a sheet like a link, and needs no writable library")
    func dataImportWaitsForSheetOnly() {
        let presenter = ScenePresenter()
        let file = URL(fileURLWithPath: "/tmp/orders.csv")
        presenter.present(.settings)
        presenter.receive(.importData(file))

        #expect(presenter.takeDeliverableIntent(isLocked: false, isLibraryWritable: false) == nil)

        presenter.sheet = nil
        #expect(presenter.takeDeliverableIntent(isLocked: false, isLibraryWritable: false) == .importData(file))
        #expect(presenter.holdsConnectionRestore == false)
    }

    @Test("An opened data file waits while an editor holds unsaved changes")
    func dataImportWaitsForEditor() {
        let presenter = ScenePresenter()
        let editor = UUID()
        presenter.setEditorHold(editor, isHolding: true)
        presenter.receive(.importData(URL(fileURLWithPath: "/tmp/orders.csv")))

        #expect(presenter.takeDeliverableIntent(isLocked: false, isLibraryWritable: true) == nil)

        presenter.setEditorHold(editor, isHolding: false)
        #expect(presenter.takeDeliverableIntent(isLocked: false, isLibraryWritable: true) != nil)
    }

    @Test("A file handed to a connection is taken once, and only by that connection")
    func dataImportTakenByItsConnection() {
        let presenter = ScenePresenter()
        let file = URL(fileURLWithPath: "/tmp/orders.csv")
        presenter.requestDataImport(file, in: connectionId)

        #expect(presenter.takeDataImport(for: UUID()) == nil)
        #expect(presenter.takeDataImport(for: connectionId) == file)
        #expect(presenter.takeDataImport(for: connectionId) == nil)
    }

    @Test("A file waiting for a connection that is no longer on screen is dropped, and one for the next is kept")
    func dataImportDiscardedWithItsConnection() {
        let presenter = ScenePresenter()
        let file = URL(fileURLWithPath: "/tmp/orders.csv")
        let next = UUID()

        presenter.requestDataImport(file, in: next)
        presenter.discardDataImport(unlessFor: next)
        #expect(presenter.pendingDataImport == PendingDataImport(connectionId: next, fileURL: file))

        presenter.discardDataImport(unlessFor: nil)
        #expect(presenter.pendingDataImport == nil)
    }

    @Test("Moving a file to another connection opens that connection the way a link does")
    func dataImportMovesToAnotherConnection() {
        let presenter = ScenePresenter()
        let file = URL(fileURLWithPath: "/tmp/orders.csv")
        let other = UUID()

        presenter.moveDataImport(file, to: other)
        #expect(presenter.restoreHolds == [.pendingIntent])
        #expect(presenter.takeDeliverableIntent(isLocked: false, isLibraryWritable: true) == .openConnection(other, table: nil))
        #expect(presenter.takeDataImport(for: other) == file)
    }

    @Test("An editor that goes away lets go of its hold", .timeLimit(.minutes(1)))
    func releasedEditorLetsGo() async {
        let presenter = ScenePresenter()
        var hold: SceneEditorHold? = SceneEditorHold()
        hold?.update(isHolding: true, in: presenter)
        #expect(presenter.isHeldByEditor)

        hold = nil
        await ObservedCondition.wait { !presenter.isHeldByEditor }
        #expect(presenter.isHeldByEditor == false)
    }
}
