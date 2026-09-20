import Foundation
@testable import TableProMobile
import Testing

@MainActor
@Suite("Scene presenter")
struct ScenePresenterTests {
    private let connectionId = UUID()

    @Test("An incoming link waits while any sheet is open, then arrives")
    func waitsForSheet() {
        let presenter = ScenePresenter(isLocked: false)
        presenter.present(.addConnection)
        presenter.receive(.openConnection(connectionId, table: nil))

        #expect(presenter.takeDeliverableIntent(isLibraryWritable: true) == nil)

        presenter.sheet = nil
        #expect(presenter.takeDeliverableIntent(isLibraryWritable: true) == .openConnection(connectionId, table: nil))
        #expect(presenter.takeDeliverableIntent(isLibraryWritable: true) == nil)
    }

    @Test("Nothing is delivered while the app is locked")
    func waitsForUnlock() {
        let presenter = ScenePresenter(isLocked: true)
        presenter.receive(.openConnection(connectionId, table: nil))

        #expect(presenter.takeDeliverableIntent(isLibraryWritable: true) == nil)

        presenter.lockDidChange(false)
        #expect(presenter.takeDeliverableIntent(isLibraryWritable: true) != nil)
    }

    @Test("A presenter born locked holds the connection restore until the first unlock")
    func lockedLaunchHoldsRestore() {
        let presenter = ScenePresenter(isLocked: true)

        #expect(presenter.isLocked)
        #expect(presenter.restoreHolds == [.appLock])
        #expect(presenter.holdsConnectionRestore)

        presenter.lockDidChange(false)
        #expect(presenter.isLocked == false)
        #expect(presenter.holdsConnectionRestore == false)
    }

    @Test("A later lock never takes the restore hold back")
    func idleLockDoesNotRetakeTheHold() {
        let presenter = ScenePresenter(isLocked: true)
        presenter.lockDidChange(false)

        presenter.lockDidChange(true)
        #expect(presenter.isLocked)
        #expect(presenter.holdsConnectionRestore == false)
    }

    @Test("A presenter born unlocked never takes the restore hold")
    func unlockedLaunchNeverHolds() {
        let presenter = ScenePresenter(isLocked: false)
        #expect(presenter.holdsConnectionRestore == false)

        presenter.lockDidChange(true)
        #expect(presenter.holdsConnectionRestore == false)
    }

    @Test("Dismissing the launch sheet leaves the lock hold standing")
    func launchSheetDismissalKeepsTheLockHold() throws {
        let fixture = try AppStateFixture()
        let appState = fixture.makeState(syncEnabled: false)
        let presenter = ScenePresenter(isLocked: true)
        presenter.present(.firstRun([.welcome]))

        presenter.sheet = nil
        presenter.sheetDidDismiss(appState: appState)
        #expect(presenter.restoreHolds == [.appLock])
        #expect(presenter.holdsConnectionRestore)

        presenter.lockDidChange(false)
        #expect(presenter.holdsConnectionRestore == false)
    }

    @Test("An import waits until the stored library can be written")
    func importWaitsForLibrary() {
        let presenter = ScenePresenter(isLocked: false)
        let file = URL(fileURLWithPath: "/tmp/Team.tablepro")
        presenter.receive(.importConnections(file))

        #expect(presenter.takeDeliverableIntent(isLibraryWritable: false) == nil)
        #expect(presenter.takeDeliverableIntent(isLibraryWritable: true) == .importConnections(file))
    }

    @Test("The latest link wins")
    func latestWins() {
        let presenter = ScenePresenter(isLocked: false)
        let other = UUID()
        presenter.receive(.openConnection(connectionId, table: nil))
        presenter.receive(.openConnection(other, table: "users"))

        #expect(presenter.takeDeliverableIntent(isLibraryWritable: true) == .openConnection(other, table: "users"))
    }

    @Test("A requested table is taken once, and only by its own connection")
    func tableRequest() {
        let presenter = ScenePresenter(isLocked: false)
        presenter.requestTable("Track", in: connectionId)

        #expect(presenter.takeTable(for: UUID()) == nil)
        #expect(presenter.takeTable(for: connectionId) == "Track")
        #expect(presenter.takeTable(for: connectionId) == nil)
    }

    @Test("A link waits while an editor holds unsaved changes, then arrives")
    func waitsForEditor() {
        let presenter = ScenePresenter(isLocked: false)
        let editor = UUID()
        presenter.setEditorHold(editor, isHolding: true)
        presenter.receive(.openConnection(connectionId, table: nil))

        #expect(presenter.isHeldByEditor)
        #expect(presenter.takeDeliverableIntent(isLibraryWritable: true) == nil)

        presenter.setEditorHold(editor, isHolding: false)
        #expect(presenter.isHeldByEditor == false)
        #expect(presenter.takeDeliverableIntent(isLibraryWritable: true) == .openConnection(connectionId, table: nil))
    }

    @Test("Every editor has to let go before a link arrives")
    func waitsForEveryEditor() {
        let presenter = ScenePresenter(isLocked: false)
        let first = UUID()
        let second = UUID()
        presenter.setEditorHold(first, isHolding: true)
        presenter.setEditorHold(second, isHolding: true)
        presenter.receive(.openConnection(connectionId, table: nil))

        presenter.setEditorHold(first, isHolding: false)
        #expect(presenter.takeDeliverableIntent(isLibraryWritable: true) == nil)

        presenter.setEditorHold(second, isHolding: false)
        #expect(presenter.takeDeliverableIntent(isLibraryWritable: true) != nil)
    }

    @Test("An editor that goes away lets go of its hold", .timeLimit(.minutes(1)))
    func releasedEditorLetsGo() async {
        let presenter = ScenePresenter(isLocked: false)
        var hold: SceneEditorHold? = SceneEditorHold()
        hold?.update(isHolding: true, in: presenter)
        #expect(presenter.isHeldByEditor)

        hold = nil
        await ObservedCondition.wait { !presenter.isHeldByEditor }
        #expect(presenter.isHeldByEditor == false)
    }
}
