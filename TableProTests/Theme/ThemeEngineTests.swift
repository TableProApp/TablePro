//
//  ThemeEngineTests.swift
//  TableProTests
//
//  The engine follows the catalog itself. Before, only the Appearance pane told it a theme had
//  changed, so a save, a move to the Trash or a file fixed in Finder left every window on the old
//  colors until Settings was opened. Each case runs its own engine on its own source, catalog and
//  change subject, so nothing the app draws with moves.
//

import AppKit
import Combine
import Foundation
@testable import TablePro
import TableProTestSupport
import TableProTheme
import Testing

@MainActor
struct ThemeEngineTests {
    @MainActor
    private final class Harness {
        let root: URL
        let center = NotificationCenter()
        let changes = PassthroughSubject<ThemeChange, Never>()
        let catalog: ThemeCatalog
        let engine: ThemeEngine
        private(set) var sent = 0
        private var cancellable: AnyCancellable?

        var themes: URL { root.appendingPathComponent("Themes", isDirectory: true) }

        init(themes seeded: [ThemeDefinition]) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ThemeEngineTests-\(UUID().uuidString)", isDirectory: true)
            let folder = root.appendingPathComponent("Themes", isDirectory: true)
            let trash = root.appendingPathComponent("Trash", isDirectory: true)
            for directory in [folder, trash] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            for theme in seeded {
                try ThemeFileFormat.encode(theme).write(to: folder.appendingPathComponent("\(theme.id).json"))
            }
            catalog = ThemeCatalog(
                userDirectory: folder,
                bundleDirectory: nil,
                notificationCenter: center,
                fileTrash: ThemeFileTrash { url in
                    let destination = trash.appendingPathComponent(url.lastPathComponent)
                    try FileManager.default.moveItem(at: url, to: destination)
                    return destination
                }
            )
            engine = ThemeEngine(catalog: catalog, changes: changes)
            cancellable = changes.sink { [weak self] _ in self?.sent += 1 }
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static func theme(_ id: String, _ appearance: ThemeAppearance, background hex: String) throws -> ThemeDefinition {
        ThemeDefinition(
            id: id,
            name: id,
            author: "",
            appearance: appearance,
            overrides: [.editorBackground: try ThemeColor(validating: hex)]
        )
    }

    private static func backgroundHex(of engine: ThemeEngine) -> String? {
        engine.activeTheme.overrides[.editorBackground]?.hex
    }

    // MARK: - Catalog changes

    @Test("Saving the theme a slot shows repaints with no view involved")
    func saveRepaints() async throws {
        let day = try Self.theme("user.day", .light, background: "#FFFFF0")
        let night = try Self.theme("user.night", .dark, background: "#101010")
        let harness = try Harness(themes: [day, night])
        defer { harness.remove() }
        harness.engine.select(lightThemeId: day.id, darkThemeId: night.id)
        #expect(harness.engine.pair == ThemePair(light: day, dark: night))
        let sentBefore = harness.sent

        var editedNight = night
        editedNight.overrides[.editorBackground] = try ThemeColor(validating: "#202020")
        try harness.catalog.save(editedNight)

        try await waitUntil { harness.engine.pair.dark == editedNight }
        #expect(harness.engine.pair.light == day)
        #expect(harness.sent > sentBefore)
        #expect(harness.engine.lightThemeId == day.id)
        #expect(harness.engine.darkThemeId == night.id)
    }

    @Test("Moving the active theme to the Trash falls back to the slot's default, and a restore brings it back")
    func trashFallsBackAndRestoreReturns() async throws {
        let night = try Self.theme("user.night", .dark, background: "#101010")
        let harness = try Harness(themes: [night])
        defer { harness.remove() }
        harness.engine.select(lightThemeId: BuiltInThemes.defaultLightId, darkThemeId: night.id)
        #expect(harness.engine.pair.dark == night)

        let receipt = try harness.catalog.trash(id: night.id)
        try await waitUntil { harness.engine.pair.dark == BuiltInThemes.dark }
        #expect(harness.engine.darkThemeId == night.id)

        try harness.catalog.restore(receipt)
        try await waitUntil { harness.engine.pair.dark == night }
    }

    @Test("A file changed on disk repaints once TablePro becomes active")
    func activationReloadRepaints() async throws {
        let night = try Self.theme("user.night", .dark, background: "#101010")
        let harness = try Harness(themes: [night])
        defer { harness.remove() }
        harness.engine.select(lightThemeId: BuiltInThemes.defaultLightId, darkThemeId: night.id)

        var fixed = night
        fixed.overrides[.editorBackground] = try ThemeColor(validating: "#303030")
        try ThemeFileFormat.encode(fixed).write(to: harness.themes.appendingPathComponent("\(night.id).json"))
        harness.center.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        try await waitUntil { harness.engine.pair.dark == fixed }
    }

    @Test("A theme imported under a saved id that was missing is picked up")
    func savedIdArrivingLater() async throws {
        let harness = try Harness(themes: [])
        defer { harness.remove() }
        harness.engine.select(lightThemeId: BuiltInThemes.defaultLightId, darkThemeId: "user.later")
        #expect(harness.engine.pair.dark == BuiltInThemes.dark)

        let later = try Self.theme("user.later", .dark, background: "#123456")
        try harness.catalog.save(later)

        try await waitUntil { harness.engine.pair.dark == later }
    }

    // MARK: - Draft preview

    @Test("A draft stands in for its theme until the preview ends")
    func draftOverlay() async throws {
        let harness = try Harness(themes: [])
        defer { harness.remove() }
        harness.engine.select(lightThemeId: BuiltInThemes.defaultLightId, darkThemeId: BuiltInThemes.defaultDarkId)
        let appearance = harness.engine.effectiveAppearance
        let saved = try Self.theme("user.edited", appearance, background: "#101010")
        try harness.catalog.save(saved)
        harness.engine.select(
            lightThemeId: appearance == .light ? saved.id : BuiltInThemes.defaultLightId,
            darkThemeId: appearance == .dark ? saved.id : BuiltInThemes.defaultDarkId
        )
        try await waitUntil { harness.engine.activeTheme == saved }

        var draft = saved
        draft.overrides[.editorBackground] = try ThemeColor(validating: "#FF0000")
        harness.engine.beginPreview(draft)

        try await waitUntil { harness.engine.activeTheme == draft }
        #expect(harness.engine.resolved.definition == draft)
        #expect(ThemeTestFixture.hex(harness.engine.resolved[.editorBackground]) == "#FF0000")
        #expect(harness.catalog.theme(id: saved.id) == saved)

        draft.overrides[.editorBackground] = try ThemeColor(validating: "#00FF00")
        harness.engine.beginPreview(draft)
        try await waitUntil { Self.backgroundHex(of: harness.engine) == "#00FF00" }

        harness.engine.endPreview(id: draft.id)
        try await waitUntil { harness.engine.activeTheme == saved }
        #expect(harness.engine.resolved.definition == saved)
    }

    @Test("A burst of draft changes resolves once")
    func draftBurstCoalesces() async throws {
        let harness = try Harness(themes: [])
        defer { harness.remove() }
        harness.engine.select(lightThemeId: BuiltInThemes.defaultLightId, darkThemeId: BuiltInThemes.defaultDarkId)
        let appearance = harness.engine.effectiveAppearance
        let saved = try Self.theme("user.edited", appearance, background: "#101010")
        try harness.catalog.save(saved)
        harness.engine.select(
            lightThemeId: appearance == .light ? saved.id : BuiltInThemes.defaultLightId,
            darkThemeId: appearance == .dark ? saved.id : BuiltInThemes.defaultDarkId
        )
        try await waitUntil { harness.engine.activeTheme == saved }
        let sentBefore = harness.sent

        var draft = saved
        for step in 0 ..< 40 {
            draft.overrides[.editorBackground] = ThemeColor(red: UInt8(step), green: 0, blue: 0)
            harness.engine.beginPreview(draft)
        }

        try await waitUntil { harness.engine.activeTheme == draft }
        #expect(harness.sent == sentBefore + 1)
    }

    @Test("A draft no slot selects changes nothing, and is used once a slot selects it")
    func unselectedDraftIsRegistered() async throws {
        let harness = try Harness(themes: [])
        defer { harness.remove() }
        let before = harness.engine.pair
        let draft = try Self.theme("user.unsaved", .dark, background: "#ABCDEF")

        harness.engine.beginPreview(draft)
        harness.engine.select(lightThemeId: before.light.id, darkThemeId: before.dark.id)
        #expect(harness.engine.pair == before)

        harness.engine.select(lightThemeId: before.light.id, darkThemeId: draft.id)
        #expect(harness.engine.pair.dark == draft)

        harness.engine.endPreview(id: draft.id)
        try await waitUntil { harness.engine.pair.dark == BuiltInThemes.dark }
    }

    @Test("A test engine leaves the shared engine and its source alone")
    func separateEngineIsolation() throws {
        let shared = ThemeEngine.shared
        let pairBefore = shared.pair
        let revisionBefore = shared.revision
        let harness = try Harness(themes: [])
        defer { harness.remove() }

        harness.engine.adopt(ThemeSelection(
            pair: ThemePair(light: BuiltInThemes.light, dark: try Self.theme("user.x", .dark, background: "#010203")),
            effectiveAppearance: .dark
        ))

        #expect(shared.pair == pairBefore)
        #expect(shared.revision == revisionBefore)
    }
}
