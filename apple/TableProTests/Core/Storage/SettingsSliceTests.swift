import Combine
import Foundation
import os
@testable import TablePro
import TableProSyncTransport
import TableProTheme
import Testing

@MainActor
private final class SliceRecorder<Value: Codable & Equatable & Sendable> {
    var publishes = 0
    var commits: [(old: Value, new: Value)] = []
    private var subscription: AnyCancellable?

    init(_ slice: SettingsSlice<Value>) {
        subscription = slice.objectWillChange.sink { [weak self] _ in self?.publishes += 1 }
        slice.attach { [weak self] old, new in self?.commits.append((old, new)) }
    }
}

@MainActor
private final class PublishCounter {
    private(set) var count = 0
    private var subscription: AnyCancellable?

    init(_ publisher: ObservableObjectPublisher) {
        subscription = publisher.sink { [weak self] _ in self?.count += 1 }
    }
}

@MainActor
private final class OutsideEffects {
    var historyRetentionApplies = 0
    var outsideResets = 0
}

// Each defaults write posts one change notification, so the log shows every write and its order.
@MainActor
private final class DefaultsWriteLog {
    private let entries = OSAllocatedUnfairLock(initialState: [String]())
    private var tokens: [NSObjectProtocol] = []

    var all: [String] { entries.withLock { $0 } }

    func watch(_ defaults: UserDefaults, as label: String) {
        let entries = entries
        let token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: nil
        ) { _ in
            entries.withLock { $0.append(label) }
        }
        tokens.append(token)
    }

    func stop() {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
        tokens.removeAll()
    }
}

@MainActor
private final class ManagerFixture {
    let storageSuite: EphemeralDefaults
    let metadataSuite: EphemeralDefaults
    let localSuite: EphemeralDefaults
    let root: URL
    let tracker: SyncChangeTracker
    let effects: OutsideEffects
    let manager: AppSettingsManager

    var storage: AppSettingsStorage { AppSettingsStorage(userDefaults: storageSuite.defaults) }

    init() throws {
        storageSuite = try EphemeralDefaults()
        metadataSuite = try EphemeralDefaults()
        localSuite = try EphemeralDefaults()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsSliceTests-\(UUID().uuidString)", isDirectory: true)
        tracker = SyncChangeTracker(metadataStorage: SyncMetadataStorage(userDefaults: metadataSuite.defaults))
        let catalog = ThemeCatalog(
            userDirectory: root.appendingPathComponent("Themes", isDirectory: true),
            bundleDirectory: nil,
            fileTrash: .folder(root.appendingPathComponent("Trash", isDirectory: true)),
            syncTracker: tracker
        )
        let effects = OutsideEffects()
        self.effects = effects
        manager = AppSettingsManager(
            storage: AppSettingsStorage(userDefaults: storageSuite.defaults),
            themeEngine: ThemeEngine(catalog: catalog),
            syncTracker: tracker,
            appEvents: AppEvents(),
            connectionListPreferences: ConnectionListPreferences(defaults: localSuite.defaults, appEvents: AppEvents()),
            passwordSyncDefaults: localSuite.defaults,
            switchSync: { _ in },
            applyHistoryRetention: { effects.historyRetentionApplies += 1 },
            resetOutsideSettings: { effects.outsideResets += 1 }
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
struct SettingsSliceTests {
    nonisolated private static func clampingMaxEntries(_ settings: HistorySettings) -> HistorySettings {
        var clamped = settings
        clamped.maxEntries = max(0, settings.maxEntries)
        return clamped
    }

    @Test("Writing the value a slice already holds neither publishes nor commits")
    func equalWriteDoesNothing() {
        let slice = SettingsSlice(NotificationSettings(isEnabled: true, thresholdSeconds: 30))
        let recorder = SliceRecorder(slice)

        slice.value = NotificationSettings(isEnabled: true, thresholdSeconds: 30)
        slice.update { $0.isEnabled = true }

        #expect(recorder.publishes == 0)
        #expect(recorder.commits.isEmpty)
    }

    @Test("A change publishes once and commits the old and new values")
    func changeCommitsOnce() {
        let slice = SettingsSlice(NotificationSettings(isEnabled: true, thresholdSeconds: 30))
        let recorder = SliceRecorder(slice)

        slice.value.isEnabled = false

        #expect(recorder.publishes == 1)
        #expect(recorder.commits.count == 1)
        #expect(recorder.commits.first?.old.isEnabled == true)
        #expect(recorder.commits.first?.new.isEnabled == false)
        #expect(!slice.value.isEnabled)
    }

    @Test("A write that needs normalizing publishes and commits the normalized value once")
    func normalizedWritePublishesOnce() {
        let slice = SettingsSlice(HistorySettings(maxEntries: 50), normalize: Self.clampingMaxEntries)
        let recorder = SliceRecorder(slice)

        slice.value.maxEntries = -5

        #expect(slice.value.maxEntries == 0)
        #expect(recorder.publishes == 1)
        #expect(recorder.commits.map { $0.new.maxEntries } == [0])

        slice.value.maxEntries = -9

        #expect(recorder.publishes == 1)
        #expect(recorder.commits.count == 1)
    }

    @Test("Building a slice never commits, so loading a value never saves it")
    func initNeverCommits() {
        let slice = SettingsSlice(HistorySettings(maxEntries: -5), normalize: Self.clampingMaxEntries)
        let recorder = SliceRecorder(slice)

        #expect(slice.value.maxEntries == -5)
        #expect(recorder.commits.isEmpty)
    }

    @Test("The publisher delivers each real change and skips equal writes")
    func publisherDeliversChanges() {
        let slice = SettingsSlice(TabSettings(enablePreviewTabs: true))
        var received: [Bool] = []
        let subscription = slice.publisher.dropFirst().sink { received.append($0.enablePreviewTabs) }
        defer { subscription.cancel() }

        slice.value.enablePreviewTabs = false
        slice.value.enablePreviewTabs = false
        slice.value.enablePreviewTabs = true

        #expect(received == [false, true])
    }

    @Test("A write through the manager publishes only its own slice, and the manager once")
    func facadeWritePublishesOnlyItsSlice() throws {
        let fixture = try ManagerFixture()
        let manager = fixture.manager
        let editor = PublishCounter(manager.editorSlice.objectWillChange)
        let general = PublishCounter(manager.generalSlice.objectWillChange)
        let dataGrid = PublishCounter(manager.dataGridSlice.objectWillChange)
        let whole = PublishCounter(manager.objectWillChange)

        manager.editor.showLineNumbers.toggle()

        #expect(editor.count == 1)
        #expect(general.count == 0)
        #expect(dataGrid.count == 0)
        #expect(whole.count == 1)
    }

    @Test("A change is saved, then marked for sync, before the assignment returns")
    func saveThenMarkBeforeReturn() throws {
        let fixture = try ManagerFixture()
        let log = DefaultsWriteLog()
        log.watch(fixture.storageSuite.defaults, as: "save")
        log.watch(fixture.metadataSuite.defaults, as: "mark")
        defer { log.stop() }

        fixture.manager.editor.showLineNumbers.toggle()

        #expect(log.all == ["save", "mark"])
        #expect(fixture.storage.loadEditor() == fixture.manager.editor)
        #expect(fixture.tracker.dirtyRecords(for: .settings) == [AppSettingsCategory.editor])
    }

    @Test("History retention is reapplied only when a retention setting changes")
    func historyRetentionOnlyOnRetentionChange() throws {
        let fixture = try ManagerFixture()
        let manager = fixture.manager

        manager.history.keepRewindHistory.toggle()

        #expect(fixture.effects.historyRetentionApplies == 0)
        #expect(fixture.storage.loadHistory().keepRewindHistory == manager.history.keepRewindHistory)
        #expect(fixture.tracker.dirtyRecords(for: .settings) == [AppSettingsCategory.history])

        manager.history.maxDays = 30
        manager.history.maxDays = 30

        #expect(fixture.effects.historyRetentionApplies == 1)

        manager.history.maxEntries = -3

        #expect(manager.history.maxEntries == 0)
        #expect(fixture.effects.historyRetentionApplies == 2)
    }

    @Test("Reset covers notifications, keeps Share usage data and marks every changed category in one write")
    func resetMarksOnce() throws {
        let fixture = try ManagerFixture()
        let manager = fixture.manager
        manager.general.shareAnalytics = false
        manager.general.showRecentTables.toggle()
        manager.notifications = NotificationSettings(isEnabled: false, thresholdSeconds: 120)
        manager.tabs.enablePreviewTabs.toggle()
        manager.editor.showLineNumbers.toggle()
        fixture.tracker.clearAllDirty(.settings)
        let log = DefaultsWriteLog()
        log.watch(fixture.metadataSuite.defaults, as: "mark")
        defer { log.stop() }

        manager.resetToDefaults()

        var expectedGeneral = GeneralSettings.default
        expectedGeneral.shareAnalytics = false
        #expect(manager.general == expectedGeneral)
        #expect(fixture.storage.loadGeneral() == expectedGeneral)
        #expect(manager.notifications == .default)
        #expect(fixture.storage.loadNotifications() == .default)
        #expect(manager.tabs == .default)
        #expect(manager.editor == .default)
        #expect(log.all == ["mark"])
        #expect(fixture.tracker.dirtyRecords(for: .settings) == [
            AppSettingsCategory.general,
            AppSettingsCategory.notifications,
            AppSettingsCategory.tabs,
            AppSettingsCategory.editor,
        ])
        #expect(fixture.effects.outsideResets == 1)
    }

    @Test("A reset with nothing to change marks nothing for sync")
    func resetOfDefaultsMarksNothing() throws {
        let fixture = try ManagerFixture()

        fixture.manager.resetToDefaults()

        #expect(fixture.tracker.dirtyRecords(for: .settings).isEmpty)
    }
}
