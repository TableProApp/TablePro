import Foundation
@testable import TablePro
import Testing

@MainActor
struct SheetWorkTests {
    @Test("Stopping the scope stops each job still in it, once")
    func stopAllStopsEachJobOnce() {
        let scope = SheetWorkScope()
        var stopped: [String] = []
        _ = scope.begin { stopped.append("export") }
        _ = scope.begin { stopped.append("transfer") }

        scope.stopAll()
        scope.stopAll()

        #expect(stopped.sorted() == ["export", "transfer"])
        #expect(scope.isEmpty)
    }

    @Test("A job that ended is not stopped")
    func endedJobIsNotStopped() {
        let scope = SheetWorkScope()
        var stopped = false
        let id = scope.begin { stopped = true }

        scope.end(id)
        scope.end(id)
        scope.end(nil)
        scope.stopAll()

        #expect(!stopped)
    }

    @Test("A sheet job is listed for the closers and leaves both lists when it ends")
    func sheetJobJoinsAndLeavesBothLists() {
        let registry = RunningWorkRegistry(providers: [])
        let scope = SheetWorkScope()
        let connectionId = UUID()
        var stopped = false
        let job = SheetJob(
            .dataExport,
            subject: "orders.csv",
            connectionName: "Production",
            connectionIds: [connectionId],
            registry: registry,
            scope: scope
        ) { stopped = true }

        #expect(registry.items(in: .connection(connectionId)).map(\.kind) == [.dataExport])
        #expect(!scope.isEmpty)

        job.end()
        scope.stopAll()

        #expect(registry.items(in: .app).isEmpty)
        #expect(scope.isEmpty)
        #expect(!stopped)
    }

    @Test("Closing another window on the same connection does not list a sheet's job")
    func sheetJobBelongsToItsWindow() {
        let registry = RunningWorkRegistry(providers: [])
        let ownWindow = UUID()
        let scope = SheetWorkScope { ownWindow }
        let connectionId = UUID()
        let job = SheetJob(
            .dataExport,
            subject: "orders.csv",
            connectionName: "Production",
            connectionIds: [connectionId],
            registry: registry,
            scope: scope
        ) {}

        #expect(registry.items(in: .window(ids: [UUID()], connectionIds: [connectionId])).isEmpty)
        #expect(registry.items(in: .window(ids: [ownWindow], connectionIds: [connectionId])).count == 1)
        #expect(registry.items(in: .connection(connectionId)).count == 1)
        job.end()
    }

    @Test("A transfer is listed for the window closing its destination's last window")
    func transferIsListedForItsDestinationWindow() {
        let registry = RunningWorkRegistry(providers: [])
        let scope = SheetWorkScope { UUID() }
        let source = UUID()
        let destination = UUID()
        let job = SheetJob(
            .tableTransfer,
            subject: "Staging",
            connectionName: "Production",
            connectionIds: [source, destination],
            registry: registry,
            scope: scope,
            listedOnlyForItsWindow: false
        ) {}

        #expect(registry.items(in: .window(ids: [UUID()], connectionIds: [destination])).count == 1)
        job.end()
    }

    @Test("The closers' question and the owner going away reach the same stop")
    func bothPathsReachTheStop() {
        let registry = RunningWorkRegistry(providers: [])
        let scope = SheetWorkScope()
        var stops = 0
        _ = SheetJob(
            .tableTransfer,
            subject: "Staging",
            connectionName: "Production",
            connectionIds: [UUID(), UUID()],
            registry: registry,
            scope: scope
        ) { stops += 1 }

        registry.cancel(registry.items(in: .app))
        #expect(stops == 1)
        scope.stopAll()
        #expect(stops == 2)
    }

    @Test("Tearing the coordinator down stops what its sheets started")
    func coordinatorTeardownStopsSheetWork() {
        let fixture = CoordinatorFixture()
        var stopped = false
        _ = fixture.coordinator.sheetWork.begin { stopped = true }

        fixture.coordinator.teardown()

        #expect(stopped)
    }

    @Test("Closing the window stops what the coordinator's sheets started")
    func windowCloseStopsSheetWork() {
        let fixture = CoordinatorFixture()
        var stopped = false
        _ = fixture.coordinator.sheetWork.begin { stopped = true }

        fixture.coordinator.handleWindowWillClose()

        #expect(stopped)
    }

    @Test("A data file window closing stops the export its sheet started")
    func presenterDismissStopsItsExport() {
        let presenter = ExportSheetPresenter()
        var stopped = false
        _ = presenter.sheetWork.begin { stopped = true }
        #expect(!stopped)

        presenter.dismiss()

        #expect(stopped)
    }
}
