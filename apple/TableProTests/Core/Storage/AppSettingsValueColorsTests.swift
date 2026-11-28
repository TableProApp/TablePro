//
//  AppSettingsValueColorsTests.swift
//  TableProTests
//

import Combine
import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

@MainActor
struct AppSettingsValueColorsTests {
    @MainActor
    private final class Harness {
        let suite: EphemeralDefaults
        let directory: URL
        let storage: AppSettingsStorage
        let settings: AppSettingsManager
        let tracker = SyncJournalRecorder()
        private(set) var sentEvents = 0
        private var subscription: AnyCancellable?

        init(saved: ValueColorSettings? = nil) throws {
            suite = try EphemeralDefaults()
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("AppSettingsValueColorsTests-\(UUID().uuidString)", isDirectory: true)
            let storage = AppSettingsStorage(userDefaults: suite.defaults)
            if let saved { storage.saveValueColors(saved) }
            let events = AppEvents()
            let catalog = ThemeCatalog(
                userDirectory: directory.appendingPathComponent("Themes", isDirectory: true),
                bundleDirectory: nil,
                fileTrash: .folder(directory.appendingPathComponent("Trash", isDirectory: true)),
                syncJournal: tracker.journal
            )
            self.storage = storage
            settings = AppSettingsManager(
                storage: storage,
                themeEngine: ThemeEngine(catalog: catalog),
                syncJournal: tracker.journal,
                appEvents: events
            )
            subscription = events.valueColorSettingsChanged.sink { [weak self] in self?.sentEvents += 1 }
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test("Turning Color values by type on saves it, tells the open grids and journals its record")
    func changeSavesSendsAndMarks() throws {
        let harness = try Harness()

        harness.settings.valueColors = ValueColorSettings(colorsValuesByType: true)

        #expect(harness.storage.loadValueColors().colorsValuesByType)
        #expect(harness.sentEvents == 1)
        #expect(harness.tracker.dirtyIds(for: .settings) == [AppSettingsCategory.valueColors])
    }

    @Test("Writing the value colors it already holds tells no grid and journals nothing")
    func unchangedWriteDoesNothing() throws {
        let harness = try Harness(saved: ValueColorSettings(colorsValuesByType: true))

        harness.settings.valueColors = ValueColorSettings(colorsValuesByType: true)

        #expect(harness.sentEvents == 0)
        #expect(harness.tracker.dirtyIds(for: .settings).isEmpty)
    }
}
