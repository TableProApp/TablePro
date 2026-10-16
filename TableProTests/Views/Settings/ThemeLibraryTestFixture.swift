import AppKit
import Foundation
@testable import TablePro
import TableProSyncTransport
import TableProTheme

/// A catalog in a temporary folder with its own trash and sync tracker, plus stand-ins for the
/// settings, the engine and the editor windows, so a theme list or editor test touches nothing real.
@MainActor
final class ThemeLibraryTestFixture {
    let root: URL
    let center = NotificationCenter()
    let suite: EphemeralDefaults
    let tracker: SyncChangeTracker
    let selection = InMemoryThemeSelection()
    let preview = RecordingThemePreview()
    let editors = StubThemeEditors()
    private(set) var catalog: ThemeCatalog

    var themes: URL { root.appendingPathComponent("Themes", isDirectory: true) }
    var trash: URL { root.appendingPathComponent("Trash", isDirectory: true) }
    var incoming: URL { root.appendingPathComponent("Incoming", isDirectory: true) }
    var drags: URL { root.appendingPathComponent("Drags", isDirectory: true) }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThemeLibraryTests-\(UUID().uuidString)", isDirectory: true)
        suite = try EphemeralDefaults()
        tracker = SyncChangeTracker(metadataStorage: SyncMetadataStorage(userDefaults: suite.defaults))
        let folders = [
            root.appendingPathComponent("Themes", isDirectory: true),
            root.appendingPathComponent("Trash", isDirectory: true),
            root.appendingPathComponent("Incoming", isDirectory: true),
        ]
        for folder in folders {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        catalog = ThemeCatalog(
            userDirectory: folders[0],
            bundleDirectory: nil,
            notificationCenter: center,
            fileTrash: .folder(folders[1]),
            syncTracker: tracker
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func makeLibrary() -> ThemeLibraryModel {
        ThemeLibraryModel(
            catalog: catalog,
            selection: selection,
            editors: editors,
            dragDirectory: drags,
            revealInFinder: { _ in }
        )
    }

    /// The window's manager groups by event; a test has no events, so each step groups itself.
    func makeEditor(
        for id: String,
        clock: any Clock<Duration> = ContinuousClock(),
        saveDelay: Duration = ThemeEditorModel.defaultSaveDelay
    ) throws -> ThemeEditorModel {
        guard let theme = catalog.storedTheme(id: id) else { throw CocoaError(.fileNoSuchFile) }
        let editor = ThemeEditorModel(
            theme: theme,
            catalog: catalog,
            preview: preview,
            selection: selection,
            clock: clock,
            saveDelay: saveDelay
        )
        editor.undoManager.groupsByEvent = false
        return editor
    }

    /// One user action, as one event makes it in a window.
    @discardableResult
    static func step<Result>(_ editor: ThemeEditorModel, _ action: () -> Result) -> Result {
        action()
    }

    static func theme(
        _ id: String,
        _ name: String,
        appearance: ThemeAppearance = .dark,
        overrides: [ThemeSlot: ThemeColor] = [:]
    ) -> ThemeDefinition {
        ThemeDefinition(id: id, name: name, author: "", appearance: appearance, overrides: overrides)
    }

    /// Writes the file and reloads, as a theme copied in with Finder arrives.
    @discardableResult
    func install(_ theme: ThemeDefinition, as fileName: String? = nil) throws -> URL {
        let url = themes.appendingPathComponent(fileName ?? "\(theme.id).json")
        try ThemeFileFormat.encode(theme).write(to: url)
        catalog.reloadSynchronously()
        return url
    }

    @discardableResult
    func writeIncoming(_ name: String, contents: Data) throws -> URL {
        let url = incoming.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    func onDisk(_ fileName: String) throws -> ThemeDefinition {
        try ThemeFileFormat.decode(try Data(contentsOf: themes.appendingPathComponent(fileName)))
    }

    func fileNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: themes.path).sorted()
    }

    static let midnightBackground = ThemeColor(red: 0x28, green: 0x2A, blue: 0x36)
    static let pink = ThemeColor(red: 0xFF, green: 0x79, blue: 0xC6)
    static let green = ThemeColor(red: 0x50, green: 0xFA, blue: 0x7B)
}

@MainActor
final class InMemoryThemeSelection: ThemeSelectionStore {
    var themeSelection = AppearanceSettings.default
}

@MainActor
final class RecordingThemePreview: ThemePreviewing {
    private(set) var drafts: [String: ThemeDefinition] = [:]
    private(set) var ended: [String] = []

    func beginPreview(_ draft: ThemeDefinition) {
        drafts[draft.id] = draft
    }

    func endPreview(id: String) {
        drafts[id] = nil
        ended.append(id)
    }
}

@MainActor
final class StubThemeEditors: ThemeEditorPresenting {
    private(set) var opened: [String] = []
    private(set) var closed: [String] = []
    var models: [String: ThemeEditorModel] = [:]

    func openEditor(for themeId: String) {
        opened.append(themeId)
    }

    func editor(for themeId: String) -> ThemeEditorModel? {
        models[themeId]
    }

    func closeEditor(for themeId: String) {
        closed.append(themeId)
        if let model = models.removeValue(forKey: themeId) {
            model.flush()
            model.close()
        }
    }
}
