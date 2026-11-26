import AppKit
import Foundation
@testable import TablePro
import TableProSyncTransport
import TableProTestSupport
import TableProTheme
import Testing

@MainActor
private final class SyncSwitchRecorder {
    var calls: [Bool] = []
    var categoryChanges = 0
}

@MainActor
struct AppSettingsSyncSideEffectsTests {
    private let pool = EphemeralDefaultsPool()

    private func makeManager(
        flagDefaults: UserDefaults,
        recorder: SyncSwitchRecorder,
        root: URL
    ) throws -> AppSettingsManager {
        let tracker = SyncJournalRecorder()
        let catalog = ThemeCatalog(
            userDirectory: root.appendingPathComponent("Themes", isDirectory: true),
            bundleDirectory: nil,
            fileTrash: .folder(root.appendingPathComponent("Trash", isDirectory: true)),
            syncJournal: tracker.journal
        )
        return AppSettingsManager(
            storage: AppSettingsStorage(userDefaults: try pool.make().defaults),
            themeEngine: ThemeEngine(catalog: catalog),
            syncJournal: tracker.journal,
            appEvents: AppEvents(),
            passwordSyncDefaults: flagDefaults,
            switchSync: { recorder.calls.append($0) },
            changeSyncCategories: { recorder.categoryChanges += 1 }
        )
    }

    private static func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSettingsSyncSideEffectsTests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("Turning sync off from anywhere, a reset included, stops password sync and the coordinator")
    func turningSyncOffReachesTheKeychainFlag() throws {
        let flagDefaults = try pool.make().defaults
        let recorder = SyncSwitchRecorder()
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try makeManager(flagDefaults: flagDefaults, recorder: recorder, root: root)

        manager.sync.enabled = true
        manager.sync.syncConnections = true
        manager.sync.syncPasswords = true
        #expect(flagDefaults.bool(forKey: KeychainHelper.passwordSyncEnabledKey))
        #expect(recorder.calls == [true])

        manager.sync = .default

        #expect(!flagDefaults.bool(forKey: KeychainHelper.passwordSyncEnabledKey))
        #expect(recorder.calls == [true, false])
    }

    @Test("A change that leaves sync on or off as it was tells the coordinator the categories, not the switch")
    func categoryChangeTellsTheCategories() throws {
        let flagDefaults = try pool.make().defaults
        let recorder = SyncSwitchRecorder()
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try makeManager(flagDefaults: flagDefaults, recorder: recorder, root: root)

        manager.sync.syncPasswords = true
        manager.sync.syncTableFavorites = false

        #expect(recorder.calls.isEmpty)
        #expect(recorder.categoryChanges == 2)
        #expect(!flagDefaults.bool(forKey: KeychainHelper.passwordSyncEnabledKey))
    }

    @Test("Writing the sync settings already held neither calls the coordinator nor rewrites the Keychain flag")
    func unchangedSyncSettingsDoNothing() throws {
        let flagDefaults = try pool.make().defaults
        let recorder = SyncSwitchRecorder()
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try makeManager(flagDefaults: flagDefaults, recorder: recorder, root: root)
        flagDefaults.set(true, forKey: KeychainHelper.passwordSyncEnabledKey)

        let current = manager.sync
        manager.sync = current

        #expect(recorder.calls.isEmpty)
        #expect(recorder.categoryChanges == 0)
        #expect(flagDefaults.bool(forKey: KeychainHelper.passwordSyncEnabledKey))
    }

    @Test("A profile that forces iCloud turns the switch on, and turns it on again after Reset All Settings")
    func forcedICloudSurvivesAReset() async throws {
        let recorder = SyncSwitchRecorder()
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try makeManager(flagDefaults: try pool.make().defaults, recorder: recorder, root: root)
        let policy = SyncProviderPolicy()

        policy.start(center: ManagedPolicyCenter(reader: ForcedICloud()), settings: manager)
        try await waitUntil { manager.sync.enabled }
        manager.sync = .default
        try await waitUntil { recorder.calls.count == 3 }

        #expect(manager.sync.enabled)
        #expect(recorder.calls == [true, false, true])
    }
}

private struct ForcedICloud: ManagedPolicyReading {
    func string(_ policy: ManagedPolicy) -> String? { nil }
    func strings(_ policy: ManagedPolicy) -> [String]? { policy == .personalSyncProvider ? ["icloud"] : nil }
}
