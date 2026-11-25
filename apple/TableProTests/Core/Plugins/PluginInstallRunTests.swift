import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

@MainActor
struct PluginInstallRunTests {
    private let pluginId = "com.example.parquet"

    @Test("The display follows the tracker entry the install reports, and a failure passes through")
    func followsTheEntryAndPassesAFailureThrough() async throws {
        let tracker = PluginInstallTracker()
        let install = PluginInstallRun(pluginName: "Parquet", tracker: tracker)
        let gate = AsyncGate()
        let pluginId = self.pluginId

        let running = Task {
            try await install.run { onBegin in
                onBegin(pluginId)
                try await tracker.track(pluginId: pluginId, displayName: "Parquet", trigger: .user, retry: nil) { ticket in
                    await ticket.reportProgress(0.5)
                    await gate.wait()
                    throw PluginError.downloadFailed("HTTP 503")
                }
            }
        }
        await gate.arrived(1)
        #expect(install.display == .make(pluginName: "Parquet", phase: .downloading(fraction: 0.5)))
        #expect(install.canCancel)

        await gate.open()
        await #expect(throws: PluginError.self) { try await running.value }
    }

    @Test("Cancel before the install names its plugin ends the run as cancelled")
    func cancelBeforeBegin() async throws {
        let install = PluginInstallRun(pluginName: "Parquet", tracker: PluginInstallTracker())
        let gate = AsyncGate()

        let running = Task {
            try await install.run { _ in
                await withTaskCancellationHandler {
                    await gate.wait()
                } onCancel: {
                    Task { await gate.open() }
                }
                try Task.checkCancellation()
            }
        }
        await gate.arrived(1)
        install.cancel()

        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(install.didCancel)
        #expect(!install.canCancel)
    }

    @Test("Cancel through the tracker entry ends the run as cancelled and removes the entry")
    func cancelThroughTheTracker() async throws {
        let tracker = PluginInstallTracker()
        let install = PluginInstallRun(pluginName: "Parquet", tracker: tracker)
        let gate = AsyncGate()
        let pluginId = self.pluginId

        let running = Task {
            try await install.run { onBegin in
                onBegin(pluginId)
                try await tracker.track(pluginId: pluginId, displayName: "Parquet", trigger: .user, retry: nil) { _ in
                    await withTaskCancellationHandler {
                        await gate.wait()
                    } onCancel: {
                        Task { await gate.open() }
                    }
                    try Task.checkCancellation()
                }
            }
        }
        await gate.arrived(1)
        install.cancel()

        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(tracker.entries[pluginId] == nil)
    }
}
