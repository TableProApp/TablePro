import AppKit
import Combine
import Foundation
import os
import SwiftUI
import TableProTheme
import UniformTypeIdentifiers

internal enum ThemeLibraryItem: Hashable, Sendable {
    case theme(String)
    case notLoaded(path: String)
}

@MainActor
internal protocol ThemeSelectionStore: AnyObject {
    var themeSelection: AppearanceSettings { get set }
}

extension AppSettingsManager: ThemeSelectionStore {
    internal var themeSelection: AppearanceSettings {
        get { appearance }
        set { appearance = newValue }
    }
}

@MainActor
internal protocol ThemeEditorPresenting: AnyObject {
    func openEditor(for themeId: String)
    func editor(for themeId: String) -> ThemeEditorModel?
    func closeEditor(for themeId: String)
}

internal struct ThemeLibraryAlert: Identifiable, Equatable {
    internal let id = UUID()
    internal let title: String
    internal let message: String

    internal static func == (lhs: ThemeLibraryAlert, rhs: ThemeLibraryAlert) -> Bool {
        lhs.title == rhs.title && lhs.message == rhs.message
    }
}

internal struct ThemeTrashConfirmation: Identifiable, Equatable {
    internal let item: ThemeLibraryItem
    internal let title: String
    internal let message: String

    internal var id: ThemeLibraryItem { item }
}

internal enum ThemeRenameOutcome: Equatable {
    case renamed(String)
    case unchanged
    case rejected(String)
}

internal struct ThemeImportFailure: Equatable {
    internal let fileName: String
    internal let reason: String
}

internal struct ThemeImportReport: Equatable {
    internal var imported: [ThemeDefinition] = []
    internal var failures: [ThemeImportFailure] = []

    /// A clean import needs no alert: the new row is selected. Anything else is one alert for the
    /// whole drop, so ten files never mean ten alerts.
    internal var alert: ThemeLibraryAlert? {
        guard !failures.isEmpty else { return nil }
        let lines = failures.map {
            String(format: String(localized: "%1$@ could not be read: %2$@"), $0.fileName, $0.reason)
        }
        if imported.isEmpty, let only = failures.first, failures.count == 1 {
            return ThemeLibraryAlert(
                title: String(format: String(localized: "Couldn't Import “%@”"), only.fileName),
                message: only.reason
            )
        }
        let title: String
        switch imported.count {
        case 0: title = String(localized: "No Themes Imported")
        case 1: title = String(localized: "Imported 1 theme.")
        default: title = String(format: String(localized: "Imported %d themes."), imported.count)
        }
        return ThemeLibraryAlert(title: title, message: lines.joined(separator: "\n"))
    }
}

internal struct ThemeFileDocument: FileDocument {
    internal static var readableContentTypes: [UTType] { [.json] }

    internal let data: Data

    internal init(data: Data) {
        self.data = data
    }

    internal init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    internal func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Every action of the Appearance pane's theme list. Views call it and show what it publishes; it
/// never reaches the engine, which follows the catalog by itself. An action on a theme whose editor
/// is open goes through that editor, so the window and the list cannot write over each other.
@MainActor
internal final class ThemeLibraryModel: ObservableObject {
    @Published internal var alert: ThemeLibraryAlert?

    internal let catalog: ThemeCatalog
    private let selection: ThemeSelectionStore
    private let editors: ThemeEditorPresenting
    private let revealInFinder: @MainActor ([URL]) -> Void
    private let dragDirectory: URL
    private var catalogCancellable: AnyCancellable?

    private static let logger = Logger(subsystem: "com.TablePro", category: "ThemeLibrary")

    internal init(
        catalog: ThemeCatalog,
        selection: ThemeSelectionStore,
        editors: ThemeEditorPresenting,
        dragDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TablePro Theme Export", isDirectory: true),
        revealInFinder: @escaping @MainActor ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
    ) {
        self.catalog = catalog
        self.selection = selection
        self.editors = editors
        self.dragDirectory = dragDirectory
        self.revealInFinder = revealInFinder
        catalogCancellable = catalog.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    // MARK: - Contents

    internal var builtInThemes: [ThemeDefinition] {
        catalog.themes.filter(\.isBuiltIn)
    }

    internal var customThemes: [ThemeDefinition] {
        catalog.themes.filter(\.isEditable)
    }

    internal var notLoaded: [RejectedThemeRecord] {
        catalog.rejected
    }

    internal func theme(for item: ThemeLibraryItem?) -> ThemeDefinition? {
        guard case let .theme(id) = item else { return nil }
        return catalog.theme(id: id)
    }

    internal func record(for item: ThemeLibraryItem?) -> RejectedThemeRecord? {
        guard case let .notLoaded(path) = item else { return nil }
        return catalog.rejected.first { $0.path == path }
    }

    internal func canTrash(_ item: ThemeLibraryItem?) -> Bool {
        if let theme = theme(for: item) { return theme.isEditable }
        return record(for: item) != nil
    }

    /// The slot a theme can still be chosen for, or nil when it is already the choice there.
    internal func availableSlot(for theme: ThemeDefinition) -> ThemeAppearance? {
        let current = selection.themeSelection
        switch theme.appearance {
        case .light: return current.preferredLightThemeId == theme.id ? nil : .light
        case .dark: return current.preferredDarkThemeId == theme.id ? nil : .dark
        }
    }

    internal static func appearanceLabel(_ appearance: ThemeAppearance) -> String {
        switch appearance {
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        }
    }

    // MARK: - Opening and choosing

    internal func edit(_ id: String) {
        guard catalog.theme(id: id) != nil else { return }
        editors.openEditor(for: id)
    }

    internal func use(_ id: String, for appearance: ThemeAppearance) {
        var updated = selection.themeSelection
        switch appearance {
        case .light: updated.preferredLightThemeId = id
        case .dark: updated.preferredDarkThemeId = id
        }
        guard updated != selection.themeSelection else { return }
        selection.themeSelection = updated
    }

    // MARK: - Creating

    @discardableResult
    internal func duplicate(_ id: String, undoManager: UndoManager?) -> ThemeDefinition? {
        makeCopy(of: id, actionName: String(localized: "Duplicate"), undoManager: undoManager)
    }

    /// A theme made to be edited, so its editor opens with it.
    @discardableResult
    internal func createTheme(basedOn id: String, undoManager: UndoManager?) -> ThemeDefinition? {
        guard let copy = makeCopy(of: id, actionName: String(localized: "New Theme"), undoManager: undoManager) else {
            return nil
        }
        editors.openEditor(for: copy.id)
        return copy
    }

    private func makeCopy(of id: String, actionName: String, undoManager: UndoManager?) -> ThemeDefinition? {
        editors.editor(for: id)?.flush()
        guard let source = catalog.storedTheme(id: id) else { return nil }
        let copy: ThemeDefinition? = perform(String(localized: "Couldn't Duplicate the Theme")) {
            try catalog.duplicate(source)
        }
        guard let copy else { return nil }
        registerCreation(of: [copy.id], actionName: actionName, undoManager: undoManager)
        return copy
    }

    internal func importThemes(from urls: [URL], undoManager: UndoManager?) -> ThemeImportReport {
        var report = ThemeImportReport()
        for url in urls where !isDragExport(url) {
            let isScoped = url.startAccessingSecurityScopedResource()
            defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
            do {
                report.imported.append(try catalog.importTheme(from: url))
            } catch {
                Self.logger.error("Theme import failed: \(error.publicLogShape, privacy: .public)")
                report.failures.append(ThemeImportFailure(fileName: url.lastPathComponent, reason: error.localizedDescription))
            }
        }
        registerCreation(of: report.imported.map(\.id), actionName: String(localized: "Import"), undoManager: undoManager)
        if let alert = report.alert {
            self.alert = alert
        }
        return report
    }

    // MARK: - Renaming

    /// The name the rename field starts from: the file's own, not the "Ocean 2" the list shows for
    /// the second of two "Ocean" themes, so committing it untouched changes nothing.
    internal func nameForRenaming(_ id: String) -> String? {
        catalog.storedTheme(id: id)?.name
    }

    internal func rename(_ id: String, to proposed: String, undoManager: UndoManager?) -> ThemeRenameOutcome {
        guard let previous = catalog.storedTheme(id: id)?.name else { return .unchanged }
        let outcome = applyRename(id, to: proposed)
        if case .renamed = outcome {
            registerRename(id, back: previous, undoManager: undoManager)
        }
        return outcome
    }

    private func applyRename(_ id: String, to proposed: String) -> ThemeRenameOutcome {
        if let editor = editors.editor(for: id) {
            let outcome = editor.rename(to: proposed)
            if case .renamed = outcome {
                editor.flush()
            }
            return outcome
        }
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let theme = catalog.storedTheme(id: id), theme.isEditable, !trimmed.isEmpty, trimmed != theme.name else {
            return .unchanged
        }
        do {
            try catalog.rename(id: id, to: trimmed)
            return .renamed(trimmed)
        } catch let error as ThemeLoadError {
            switch error {
            case .nameTaken, .invalidName:
                return .rejected(error.localizedDescription)
            default:
                fail(String(localized: "Couldn't Rename the Theme"), error)
                return .unchanged
            }
        } catch {
            fail(String(localized: "Couldn't Rename the Theme"), error)
            return .unchanged
        }
    }

    private func registerRename(_ id: String, back name: String, undoManager: UndoManager?) {
        guard let undoManager else { return }
        register(on: undoManager, actionName: String(localized: "Rename")) { model in
            guard let current = model.catalog.storedTheme(id: id)?.name else { return }
            if case let .rejected(reason) = model.applyRename(id, to: name) {
                model.alert = ThemeLibraryAlert(title: String(localized: "Couldn't Rename the Theme"), message: reason)
                return
            }
            model.registerRename(id, back: current, undoManager: undoManager)
        }
    }

    // MARK: - Export

    internal func exportDocument(for id: String) -> ThemeFileDocument? {
        editors.editor(for: id)?.flush()
        guard let theme = catalog.storedTheme(id: id) else { return nil }
        return perform(String(localized: "Couldn't Export the Theme")) {
            ThemeFileDocument(data: try ThemeFileFormat.encode(theme))
        }
    }

    internal static func exportFileName(for theme: ThemeDefinition) -> String {
        let reserved = CharacterSet(charactersIn: "/:")
        let cleaned = theme.name.components(separatedBy: reserved).joined(separator: "-")
        return cleaned.isEmpty ? theme.id : cleaned
    }

    /// A copy in a folder of its own rather than the theme's file, because Finder may move a dragged
    /// file instead of copying it, and a built-in theme has no file.
    internal func dragExportURL(for id: String) throws -> URL {
        editors.editor(for: id)?.flush()
        guard let theme = catalog.storedTheme(id: id) else { throw CocoaError(.fileNoSuchFile) }
        let folder = dragDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(Self.exportFileName(for: theme) + ".json", isDirectory: false)
        try ThemeFileFormat.encode(theme).write(to: url, options: .atomic)
        return url
    }

    internal func dragItemProvider(for id: String) -> NSItemProvider {
        do {
            let url = try dragExportURL(for: id)
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        } catch {
            Self.logger.error("Theme drag export failed: \(error.publicLogShape, privacy: .public)")
            return NSItemProvider()
        }
    }

    private func isDragExport(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(dragDirectory.standardizedFileURL.path + "/")
    }

    // MARK: - Finder

    internal func revealInFinder(_ item: ThemeLibraryItem?) {
        if case let .theme(id) = item, let url = catalog.fileURL(for: id) {
            revealInFinder([url])
        } else if let record = record(for: item) {
            revealInFinder([URL(fileURLWithPath: record.path)])
        } else {
            revealInFinder([catalog.themesDirectory])
        }
    }

    internal func retryLoading() {
        catalog.reloadSynchronously()
    }

    // MARK: - Trash

    /// Asked only when the trash changes what the windows draw. Moving a theme nothing uses is undone
    /// from the Edit menu, so it needs no alert.
    internal func trashConfirmation(for item: ThemeLibraryItem) -> ThemeTrashConfirmation? {
        guard let theme = theme(for: item), theme.isEditable else { return nil }
        let current = selection.themeSelection
        let holdsLight = current.preferredLightThemeId == theme.id
        let holdsDark = current.preferredDarkThemeId == theme.id
        let message: String
        switch (holdsLight, holdsDark) {
        case (false, false):
            return nil
        case (true, false):
            message = String(
                format: String(localized: "The file moves to the Trash. Light windows switch to %@."),
                BuiltInThemes.light.name
            )
        case (false, true):
            message = String(
                format: String(localized: "The file moves to the Trash. Dark windows switch to %@."),
                BuiltInThemes.dark.name
            )
        case (true, true):
            message = String(localized: "The file moves to the Trash. Light and dark windows switch to their default themes.")
        }
        return ThemeTrashConfirmation(
            item: item,
            title: String(format: String(localized: "Delete “%@”?"), theme.name),
            message: message
        )
    }

    @discardableResult
    internal func moveToTrash(_ item: ThemeLibraryItem, undoManager: UndoManager?) -> Bool {
        switch item {
        case let .theme(id):
            guard let theme = catalog.theme(id: id), theme.isEditable else { return false }
            editors.closeEditor(for: id)
            let before = selection.themeSelection
            let receipt: ThemeTrashReceipt? = perform(String(localized: "Couldn't Move the Theme to the Trash")) {
                try catalog.trash(id: id)
            }
            guard let receipt else { return false }
            let released = before.releasing(themeId: id)
            if released != before {
                selection.themeSelection = released
            }
            registerRestore(receipt, item: item, releasedFrom: before, undoManager: undoManager)
            return true
        case let .notLoaded(path):
            let receipt: ThemeTrashReceipt? = perform(String(localized: "Couldn't Move the File to the Trash")) {
                try catalog.trashRejected(path: path)
            }
            guard let receipt else { return false }
            registerRestore(receipt, item: item, releasedFrom: nil, undoManager: undoManager)
            return true
        }
    }

    private func registerRestore(
        _ receipt: ThemeTrashReceipt,
        item: ThemeLibraryItem,
        releasedFrom before: AppearanceSettings?,
        undoManager: UndoManager?
    ) {
        guard let undoManager else { return }
        register(on: undoManager, actionName: String(localized: "Move to Trash")) { model in
            model.restore(receipt, item: item, releasedFrom: before, undoManager: undoManager)
        }
    }

    private func restore(
        _ receipt: ThemeTrashReceipt,
        item: ThemeLibraryItem,
        releasedFrom before: AppearanceSettings?,
        undoManager: UndoManager
    ) {
        let restored: Bool? = perform(String(localized: "Couldn't Put the Theme Back")) {
            try catalog.restore(receipt)
            return true
        }
        guard restored != nil else { return }
        if let before, case let .theme(id) = item {
            let reclaimed = selection.themeSelection.reclaiming(themeId: id, from: before)
            if reclaimed != selection.themeSelection {
                selection.themeSelection = reclaimed
            }
        }
        register(on: undoManager, actionName: String(localized: "Move to Trash")) { model in
            _ = model.moveToTrash(item, undoManager: undoManager)
        }
    }

    // MARK: - Undoing a creation

    /// The way Finder undoes a duplicate: the new file goes to the Trash, and Redo brings it back.
    private func registerCreation(of ids: [String], actionName: String, undoManager: UndoManager?) {
        guard let undoManager, !ids.isEmpty else { return }
        register(on: undoManager, actionName: actionName) { model in
            model.undoCreation(of: ids, actionName: actionName, undoManager: undoManager)
        }
    }

    private func undoCreation(of ids: [String], actionName: String, undoManager: UndoManager) {
        var receipts: [ThemeTrashReceipt] = []
        for id in ids where catalog.theme(id: id) != nil {
            editors.closeEditor(for: id)
            let before = selection.themeSelection
            let receipt: ThemeTrashReceipt? = perform(String(localized: "Couldn't Move the Theme to the Trash")) {
                try catalog.trash(id: id)
            }
            guard let receipt else { continue }
            receipts.append(receipt)
            let released = before.releasing(themeId: id)
            if released != before {
                selection.themeSelection = released
            }
        }
        register(on: undoManager, actionName: actionName) { model in
            model.redoCreation(receipts, ids: ids, actionName: actionName, undoManager: undoManager)
        }
    }

    private func redoCreation(_ receipts: [ThemeTrashReceipt], ids: [String], actionName: String, undoManager: UndoManager) {
        for receipt in receipts {
            _ = perform(String(localized: "Couldn't Put the Theme Back")) {
                try catalog.restore(receipt)
            }
        }
        registerCreation(of: ids, actionName: actionName, undoManager: undoManager)
    }

    /// A group of its own, so each action is one undo whether or not the manager groups by event.
    private func register(
        on undoManager: UndoManager,
        actionName: String,
        _ handler: @escaping @MainActor (ThemeLibraryModel) -> Void
    ) {
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                handler(model)
            }
        }
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()
    }

    // MARK: - Failures

    private func perform<Value>(_ title: String, _ work: () throws -> Value) -> Value? {
        do {
            return try work()
        } catch {
            fail(title, error)
            return nil
        }
    }

    private func fail(_ title: String, _ error: Error) {
        Self.logger.error("Theme action failed: \(error.publicLogShape, privacy: .public)")
        alert = ThemeLibraryAlert(title: title, message: error.localizedDescription)
    }
}

internal extension AppearanceSettings {
    /// A slot that held a theme the user just trashed goes back to its built-in, so the popup does
    /// not then report that theme as missing.
    func releasing(themeId: String) -> AppearanceSettings {
        var updated = self
        if updated.preferredLightThemeId == themeId {
            updated.preferredLightThemeId = BuiltInThemes.defaultLightId
        }
        if updated.preferredDarkThemeId == themeId {
            updated.preferredDarkThemeId = BuiltInThemes.defaultDarkId
        }
        return updated
    }

    /// Undo of a trash puts the theme back only into the slots the trash released and nothing has
    /// chosen since.
    func reclaiming(themeId: String, from before: AppearanceSettings) -> AppearanceSettings {
        var updated = self
        if before.preferredLightThemeId == themeId, updated.preferredLightThemeId == BuiltInThemes.defaultLightId {
            updated.preferredLightThemeId = themeId
        }
        if before.preferredDarkThemeId == themeId, updated.preferredDarkThemeId == BuiltInThemes.defaultDarkId {
            updated.preferredDarkThemeId = themeId
        }
        return updated
    }
}
