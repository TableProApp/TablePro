import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

private actor GatedRegistryInstaller: RegistryPluginInstalling {
    private let gate: AsyncGate

    init(gate: AsyncGate) {
        self.gate = gate
    }

    func install(
        _ registryPlugin: RegistryPlugin,
        release: RegistryRelease,
        into userPluginsDir: URL,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> URL {
        await progress(0.25)
        await gate.wait()
        throw PluginError.downloadFailed("HTTP 503")
    }

    func stage(
        _ registryPlugin: RegistryPlugin,
        release: RegistryRelease,
        pluginId: String,
        bundleName: String,
        into userPluginsDir: URL,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> URL {
        throw PluginError.downloadFailed("HTTP 503")
    }
}

@MainActor
struct PluginInstallTrackerTests {
    private func track(
        _ tracker: PluginInstallTracker,
        _ pluginId: String = "com.example.driver",
        trigger: PluginInstallTracker.Trigger = .user,
        body: @escaping @MainActor @Sendable (PluginInstallTracker.Ticket) async throws -> Void = { _ in }
    ) async throws {
        try await tracker.track(pluginId: pluginId, displayName: "Driver", trigger: trigger, retry: nil, body)
    }

    private func isFailed(_ phase: PluginInstallTracker.Phase?) -> Bool {
        if case .failed = phase { return true }
        return false
    }

    @Test("A completed install leaves after its lifetime, and an earlier completion never removes a later install")
    func completionTimerChecksTheGeneration() async throws {
        let clock = ManualClock()
        let tracker = PluginInstallTracker(clock: clock)
        try await track(tracker)
        let first = try #require(tracker.entries["com.example.driver"])
        #expect(first.phase == .completed)
        await clock.waitUntilSleeping()

        let gate = AsyncGate()
        let second = Task { try await track(tracker) { _ in await gate.wait() } }
        await gate.arrived(1)
        let running = try #require(tracker.entries["com.example.driver"])
        #expect(running.generation != first.generation)

        clock.advance(by: PluginInstallTracker.completedLifetime)
        tracker.removeCompleted(pluginId: "com.example.driver", generation: first.generation)
        #expect(tracker.entries["com.example.driver"]?.generation == running.generation)
        #expect(tracker.entries["com.example.driver"]?.phase.isRunning == true)

        await gate.open()
        try await second.value
        #expect(tracker.entries["com.example.driver"]?.phase == .completed)
        await clock.waitUntilSleeping()
        clock.advance(by: PluginInstallTracker.completedLifetime)
        try await waitUntil { tracker.entries["com.example.driver"] == nil }
    }

    @Test("A failure stays past every timer until it is dismissed, and a later install replaces it")
    func failurePersists() async throws {
        let clock = ManualClock()
        let tracker = PluginInstallTracker(clock: clock)
        await #expect(throws: PluginError.self) {
            try await track(tracker) { _ in throw PluginError.checksumMismatch }
        }
        let failed = try #require(tracker.entries["com.example.driver"])
        #expect(failed.phase == .failed(PluginError.checksumMismatch.localizedDescription))

        try await track(tracker, "com.example.other")
        await clock.waitUntilSleeping()
        #expect(clock.pendingSleeperCount == 1)
        clock.advance(by: .seconds(600))
        try await waitUntil { tracker.entries["com.example.other"] == nil }
        #expect(tracker.entries["com.example.driver"]?.generation == failed.generation)
        #expect(isFailed(tracker.entries["com.example.driver"]?.phase))

        try await track(tracker)
        #expect(tracker.entries["com.example.driver"]?.phase == .completed)
        #expect(tracker.entries["com.example.driver"]?.generation != failed.generation)

        await #expect(throws: PluginError.self) {
            try await track(tracker, "com.example.third") { _ in throw PluginError.notFound }
        }
        tracker.cancel(pluginId: "com.example.third")
        #expect(tracker.entries["com.example.third"] == nil)
    }

    @Test("Cancelling a running install removes its entry and records no failure")
    func cancelRemovesWithoutFailure() async throws {
        let tracker = PluginInstallTracker(clock: ManualClock())
        let gate = AsyncGate()
        let install = Task {
            try await track(tracker) { _ in
                await gate.wait()
                try Task.checkCancellation()
            }
        }
        await gate.arrived(1)
        #expect(tracker.isInstalling)

        tracker.cancel(pluginId: "com.example.driver")
        await gate.open()

        await #expect(throws: CancellationError.self) { try await install.value }
        #expect(tracker.entries["com.example.driver"] == nil)
        #expect(!tracker.isInstalling)
    }

    @Test("A download the network cancels counts as a cancel, not a failure")
    func urlCancellationIsACancel() async throws {
        let tracker = PluginInstallTracker(clock: ManualClock())
        await #expect(throws: CancellationError.self) {
            try await track(tracker) { _ in throw URLError(.cancelled) }
        }
        #expect(tracker.entries["com.example.driver"] == nil)
    }

    @Test("A second install of a running plugin is refused and leaves the first one running")
    func duplicateIsRefused() async throws {
        let tracker = PluginInstallTracker(clock: ManualClock())
        let gate = AsyncGate()
        let first = Task { try await track(tracker) { _ in await gate.wait() } }
        await gate.arrived(1)
        let running = try #require(tracker.entries["com.example.driver"])

        await #expect(throws: PluginError.self) { try await track(tracker) }
        #expect(tracker.entries["com.example.driver"]?.generation == running.generation)
        #expect(tracker.entries["com.example.driver"]?.phase.isRunning == true)

        await gate.open()
        try await first.value
        #expect(tracker.entries["com.example.driver"]?.phase == .completed)
    }

    @Test("A joined install waits for the running one and shares its outcome")
    func joinWaitsForTheRunningInstall() async throws {
        let tracker = PluginInstallTracker(clock: ManualClock())
        #expect(try await tracker.joinRunningInstall(of: "com.example.driver") == false)

        let gate = AsyncGate()
        let first = Task { try await track(tracker) { _ in await gate.wait() } }
        await gate.arrived(1)
        let joined = Task { try await tracker.joinRunningInstall(of: "com.example.driver") }
        await gate.open()

        #expect(try await joined.value)
        try await first.value
    }

    @Test("Progress below 1 is the download; 1 and markInstalling move to installing, never back")
    func progressMapsToPhases() async throws {
        let tracker = PluginInstallTracker(clock: ManualClock())
        let downloading = AsyncGate()
        let installing = AsyncGate()
        let install = Task {
            try await track(tracker) { ticket in
                await ticket.reportProgress(0.4)
                await downloading.wait()
                await ticket.reportProgress(1)
                await ticket.reportProgress(0.5)
                await installing.wait()
            }
        }
        await downloading.arrived(1)
        #expect(tracker.entries["com.example.driver"]?.phase == .downloading(fraction: 0.4))
        await downloading.open()
        await installing.arrived(1)
        #expect(tracker.entries["com.example.driver"]?.phase == .installing)
        await installing.open()
        try await install.value
    }

    @Test("A second registry install of a downloading plugin never resets or fails the first")
    func registryDuplicateKeepsTheRunningEntry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginInstallTrackerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = AsyncGate()
        let tracker = PluginInstallTracker(clock: ManualClock())
        let manager = PluginManager(
            builtInPluginsURL: nil,
            userPluginsDir: root.appendingPathComponent("Plugins", isDirectory: true),
            registryInstaller: GatedRegistryInstaller(gate: gate),
            installTracker: tracker,
            isUpdatingEnabled: false
        )
        let release = RegistryRelease(
            version: "1.0", build: 2, channel: "stable", pluginKit: PluginManager.currentPluginKitVersion,
            minimumSystemVersion: "13.0", url: "https://x", sha256: "deadbeef"
        )
        let plugin = RegistryPlugin(
            id: "com.example.driver", name: "Driver", databaseTypeIds: [], exportFormatIds: [], releases: [release]
        )

        let first = Task { try await manager.installFromRegistry(plugin, release: release, trigger: .user) }
        await gate.arrived(1)
        let running = try #require(tracker.entries[plugin.id])
        #expect(running.phase == .downloading(fraction: 0.25))

        await #expect(throws: PluginError.self) {
            try await manager.installFromRegistry(plugin, release: release, trigger: .user)
        }
        #expect(tracker.entries[plugin.id]?.generation == running.generation)
        #expect(tracker.entries[plugin.id]?.phase == .downloading(fraction: 0.25))

        await gate.open()
        await #expect(throws: PluginError.self) { try await first.value }
        #expect(tracker.entries[plugin.id]?.generation == running.generation)
        #expect(isFailed(tracker.entries[plugin.id]?.phase))
    }

    @Test("The install sheet says downloading, then installing, with a bar only when the size is known")
    func presenterDisplayFollowsThePhase() {
        typealias Display = PluginInstallProgressPresenter.Display
        let downloading = String(format: String(localized: "Downloading the %@ plugin…"), "Oracle")
        let installing = String(format: String(localized: "Installing the %@ plugin…"), "Oracle")

        #expect(Display.make(pluginName: "Oracle", phase: nil)
            == Display(message: downloading, fraction: nil, canCancel: true))
        #expect(Display.make(pluginName: "Oracle", phase: .downloading(fraction: nil))
            == Display(message: downloading, fraction: nil, canCancel: true))
        #expect(Display.make(pluginName: "Oracle", phase: .downloading(fraction: 0.5))
            == Display(message: downloading, fraction: 0.5, canCancel: true))
        #expect(Display.make(pluginName: "Oracle", phase: .installing)
            == Display(message: installing, fraction: nil, canCancel: false))
        #expect(Display.make(pluginName: "Oracle", phase: .completed)
            == Display(message: installing, fraction: nil, canCancel: false))
    }
}
