import Foundation
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

    @Test("Dismissing the launch sheet leaves the lock hold standing")
    func launchSheetDismissalKeepsTheLockHold() throws {
        let fixture = try AppStateFixture()
        let appState = fixture.makeState(syncEnabled: false)
        let presenter = ScenePresenter(isLockedAtLaunch: true)
        presenter.present(.firstRun([.welcome]))

        presenter.sheet = nil
        presenter.sheetDidDismiss(appState: appState)
        #expect(presenter.restoreHolds == [.appLock])
        #expect(presenter.holdsConnectionRestore)

        presenter.lockDidChange(false)
        #expect(presenter.holdsConnectionRestore == false)
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
