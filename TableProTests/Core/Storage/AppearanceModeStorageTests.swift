//
//  AppearanceModeStorageTests.swift
//  TableProTests
//
//  The Auto, Light or Dark mode used to sit inside the synced appearance blob, so a change on one
//  Mac flipped every other Mac. It now has its own device-local key, carried out of the blob once.
//

import AppKit
import Foundation
@testable import TablePro
import TableProSyncTransport
import TableProTheme
import Testing

@MainActor
struct AppearanceModeStorageTests {
    private static let appearanceKey = "com.TablePro.settings.appearance"
    private static let modeKey = "com.TablePro.settings.appearanceMode"
    private static let legacyBlob = #"{"appearanceMode":"dark","preferredLightThemeId":"user.day","preferredDarkThemeId":"user.night"}"#

    private let suite: EphemeralDefaults

    init() throws {
        suite = try EphemeralDefaults()
    }

    private var defaults: UserDefaults { suite.defaults }

    // MARK: - Storage

    @Test("The mode an older build kept in the appearance blob moves to its own key on the first load")
    func legacyModeIsCarriedOnce() {
        defaults.set(Data(Self.legacyBlob.utf8), forKey: Self.appearanceKey)
        let storage = AppSettingsStorage(userDefaults: defaults)

        #expect(storage.loadAppearanceMode() == .dark)
        #expect(defaults.string(forKey: Self.modeKey) == "dark")
        #expect(storage.loadAppearance() == AppearanceSettings(preferredLightThemeId: "user.day", preferredDarkThemeId: "user.night"))
    }

    @Test("Saving the theme ids after the carry-over keeps the mode the blob held")
    func carriedModeSurvivesTheNextSave() {
        defaults.set(Data(Self.legacyBlob.utf8), forKey: Self.appearanceKey)
        let storage = AppSettingsStorage(userDefaults: defaults)
        _ = storage.loadAppearanceMode()

        storage.saveAppearance(AppearanceSettings(preferredLightThemeId: "user.day", preferredDarkThemeId: "user.other"))

        #expect(storage.loadAppearanceMode() == .dark)
    }

    @Test("The device-local key wins over a mode still in the blob")
    func ownKeyWins() {
        defaults.set(Data(Self.legacyBlob.utf8), forKey: Self.appearanceKey)
        defaults.set("light", forKey: Self.modeKey)

        #expect(AppSettingsStorage(userDefaults: defaults).loadAppearanceMode() == .light)
    }

    @Test("A fresh install starts on Auto and records it")
    func freshInstallIsAuto() {
        let storage = AppSettingsStorage(userDefaults: defaults)

        #expect(storage.loadAppearanceMode() == .auto)
        #expect(defaults.string(forKey: Self.modeKey) == "auto")
    }

    @Test("A stored value this build does not know reads as Auto")
    func unknownValueIsAuto() {
        defaults.set("sepia", forKey: Self.modeKey)

        #expect(AppSettingsStorage(userDefaults: defaults).loadAppearanceMode() == .auto)
    }

    @Test("The appearance blob no longer carries a mode")
    func blobHasNoMode() throws {
        let storage = AppSettingsStorage(userDefaults: defaults)
        storage.saveAppearanceMode(.dark)
        storage.saveAppearance(AppearanceSettings(preferredLightThemeId: "user.day", preferredDarkThemeId: "user.night"))

        let data = try #require(defaults.data(forKey: Self.appearanceKey))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["preferredLightThemeId", "preferredDarkThemeId"])
    }

    @Test("Reset returns the mode to Auto")
    func resetReturnsToAuto() {
        let storage = AppSettingsStorage(userDefaults: defaults)
        storage.saveAppearanceMode(.dark)

        storage.resetToDefaults()

        #expect(storage.loadAppearanceMode() == .auto)
    }

    // MARK: - Manager

    private func makeManager(tracker: SyncChangeTracker, root: URL) -> (AppSettingsManager, ThemeEngine) {
        let catalog = ThemeCatalog(
            userDirectory: root.appendingPathComponent("Themes", isDirectory: true),
            bundleDirectory: nil,
            notificationCenter: NotificationCenter(),
            fileTrash: .folder(root.appendingPathComponent("Trash", isDirectory: true)),
            syncTracker: tracker
        )
        let engine = ThemeEngine(catalog: catalog)
        let manager = AppSettingsManager(
            storage: AppSettingsStorage(userDefaults: defaults),
            themeEngine: engine,
            syncTracker: tracker,
            appEvents: AppEvents()
        )
        return (manager, engine)
    }

    private static func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AppearanceModeStorageTests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("Changing the mode saves it on this Mac, applies it, and marks nothing for sync")
    func modeChangeStaysLocal() throws {
        let syncSuite = try EphemeralDefaults()
        let tracker = SyncChangeTracker(metadataStorage: SyncMetadataStorage(userDefaults: syncSuite.defaults))
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (manager, engine) = makeManager(tracker: tracker, root: root)
        let original = NSApp.appearance
        defer { NSApp.appearance = original }

        manager.appearanceMode = .dark

        #expect(AppSettingsStorage(userDefaults: defaults).loadAppearanceMode() == .dark)
        #expect(engine.mode == .dark)
        #expect(tracker.dirtyRecords(for: .settings).isEmpty)

        manager.appearanceMode = .auto
        #expect(engine.mode == .auto)
    }

    @Test("Changing a theme id marks the appearance record and leaves the mode")
    func themeChangeSyncs() throws {
        let syncSuite = try EphemeralDefaults()
        let tracker = SyncChangeTracker(metadataStorage: SyncMetadataStorage(userDefaults: syncSuite.defaults))
        let root = Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (manager, engine) = makeManager(tracker: tracker, root: root)

        manager.appearance = AppearanceSettings(preferredDarkThemeId: "user.night")

        #expect(tracker.dirtyRecords(for: .settings) == [AppSettingsCategory.appearance])
        #expect(manager.appearanceMode == .auto)
        #expect(engine.darkThemeId == "user.night")
    }
}
