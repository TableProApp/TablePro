import AppKit
import Combine
import Foundation
import os
import TableProTheme

@MainActor
internal protocol ThemePreviewing: AnyObject {
    func beginPreview(_ draft: ThemeDefinition)
    func endPreview(id: String)
}

extension ThemeEngine: ThemePreviewing {}

/// One open theme. The draft is saved a moment after it settles and on close, previewed in every
/// window while it is edited, and undone one settled step at a time. The catalog reloads whenever
/// TablePro becomes active, so a file changed or removed elsewhere is noticed here before a save
/// could write over it.
@MainActor
internal final class ThemeEditorModel: ObservableObject {
    internal enum Alert: Identifiable, Equatable {
        case changedOnDisk(name: String)
        case unreadableOnDisk(name: String)
        case deletedOnDisk(name: String)
        case saveFailed(name: String, reason: String)

        internal var id: String {
            switch self {
            case .changedOnDisk: return "changed"
            case .unreadableOnDisk: return "unreadable"
            case .deletedOnDisk: return "deleted"
            case .saveFailed: return "save"
            }
        }
    }

    internal enum CloseDecision: Equatable {
        case close
        case keepEditing
        case confirmDiscard(name: String, reason: String)
    }

    @Published internal private(set) var draft: ThemeDefinition
    @Published internal private(set) var openingSnapshot: ThemeDefinition
    @Published internal private(set) var previewScope: ThemeScope
    @Published internal private(set) var fileURL: URL?
    @Published internal private(set) var isDetached = false
    @Published internal var alert: Alert?
    @Published internal var nameText: String
    @Published internal var authorText: String
    @Published internal private(set) var nameError: String?
    @Published internal private(set) var authorError: String?

    internal let undoManager = UndoManager()
    internal let isReadOnly: Bool
    internal var onRequestClose: (() -> Void)?
    internal var onIdentifierChange: ((_ old: String, _ new: String) -> Void)?

    internal var isEditable: Bool { !isReadOnly && !isDetached }
    internal var hasChangesSinceOpening: Bool { draft != openingSnapshot }

    private let catalog: ThemeCatalog
    private let preview: ThemePreviewing
    private let selection: ThemeSelectionStore?
    private let clock: any Clock<Duration>
    private let saveDelay: Duration
    private var lastSaved: ThemeDefinition
    private var saveTask: Task<Void, Never>?
    private var catalogCancellable: AnyCancellable?
    private var isSaving = false
    private var isClosed = false
    /// The slot whose well is still being dragged. Its ticks share one undo step until the drag
    /// settles, which is when the debounced save runs.
    private var settlingSlot: ThemeSlot?

    private static let logger = Logger(subsystem: "com.TablePro", category: "ThemeEditor")

    internal static let defaultSaveDelay = Duration.milliseconds(750)

    internal init(
        theme: ThemeDefinition,
        catalog: ThemeCatalog,
        preview: ThemePreviewing,
        selection: ThemeSelectionStore?,
        clock: any Clock<Duration> = ContinuousClock(),
        saveDelay: Duration = ThemeEditorModel.defaultSaveDelay
    ) {
        draft = theme
        openingSnapshot = theme
        lastSaved = theme
        previewScope = .fixed(theme)
        nameText = theme.name
        authorText = theme.author
        isReadOnly = !theme.isEditable
        fileURL = catalog.fileURL(for: theme.id)
        self.catalog = catalog
        self.preview = preview
        self.selection = selection
        self.clock = clock
        self.saveDelay = saveDelay
        guard !isReadOnly else { return }
        catalogCancellable = catalog.$themes.sink { [weak self] _ in
            self?.catalogWillPublish()
        }
    }

    // MARK: - Edits

    /// A well echoes the color it was handed. Taking that echo for an edit would freeze a system
    /// color into the file, so a value equal to what an unset slot shows is ignored.
    internal func setColor(_ color: ThemeColor, for slot: ThemeSlot) {
        guard isEditable else { return }
        let value = slot.offersOpacity ? color : color.opaque
        if let existing = draft.overrides[slot] {
            guard existing != value else { return }
        } else {
            guard ThemeSlotPresentation.displayColor(for: slot, in: draft) != value else { return }
        }
        if settlingSlot != slot {
            registerUndo(restoring: draft, actionName: String(localized: "Color Change"))
            settlingSlot = slot
        }
        var next = draft
        next.overrides[slot] = value
        commit(next)
    }

    internal func reset(_ slot: ThemeSlot) {
        guard isEditable, draft.hasExplicitColor(slot) else { return }
        settlingSlot = nil
        registerUndo(restoring: draft, actionName: ThemeSlotPresentation.resetTitle(for: slot, in: draft))
        var next = draft
        next.overrides[slot] = nil
        commit(next)
    }

    internal func setAppearance(_ appearance: ThemeAppearance) {
        guard isEditable, appearance != draft.appearance else { return }
        settlingSlot = nil
        registerUndo(restoring: draft, actionName: String(localized: "Appearance Change"))
        var next = draft
        next.appearance = appearance
        commit(next)
    }

    @discardableResult
    internal func commitName() -> ThemeRenameOutcome {
        rename(to: nameText)
    }

    /// A taken or malformed name keeps the field as typed with the reason under it, rather than
    /// numbering it or dropping it behind the user's back.
    @discardableResult
    internal func rename(to proposed: String) -> ThemeRenameOutcome {
        guard isEditable else { return .unchanged }
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != draft.name else {
            nameText = draft.name
            nameError = nil
            return .unchanged
        }
        var next = draft
        next.name = trimmed
        if let problem = nameProblem(in: next) {
            nameText = proposed
            nameError = problem
            return .rejected(problem)
        }
        settlingSlot = nil
        registerUndo(restoring: draft, actionName: String(localized: "Rename"))
        commit(next)
        return .renamed(trimmed)
    }

    /// False when the text is refused, which then stays in the field with the reason.
    @discardableResult
    internal func commitAuthor() -> Bool {
        guard isEditable else { return true }
        let trimmed = authorText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != draft.author else {
            authorText = draft.author
            authorError = nil
            return true
        }
        var next = draft
        next.author = trimmed
        guard isEncodable(next) else {
            authorError = ThemeLoadError.invalidAuthor.localizedDescription
            return false
        }
        settlingSlot = nil
        registerUndo(restoring: draft, actionName: String(localized: "Author Change"))
        commit(next)
        return true
    }

    internal func revert() {
        guard isEditable, hasChangesSinceOpening else { return }
        settlingSlot = nil
        registerUndo(restoring: draft, actionName: String(localized: "Revert Changes"))
        var next = openingSnapshot
        next.id = draft.id
        commit(next)
    }

    private func commit(_ next: ThemeDefinition) {
        showFields(of: next, replacing: draft)
        draft = next
        previewScope = .fixed(next)
        preview.beginPreview(next)
        scheduleSave()
    }

    /// A field follows the draft only where the draft's value changed. Name and Author commit when
    /// focus leaves them, and a well click takes no focus, so a color picked mid-typing would
    /// otherwise put the old name back under the caret.
    private func showFields(of next: ThemeDefinition, replacing previous: ThemeDefinition) {
        if next.name != previous.name {
            nameText = next.name
            nameError = nil
        }
        if next.author != previous.author {
            authorText = next.author
            authorError = nil
        }
    }

    private func nameProblem(in candidate: ThemeDefinition) -> String? {
        let name = candidate.name
        let isTaken = catalog.themes.contains { other in
            other.id != candidate.id
                && other.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .compare(name, options: .caseInsensitive) == .orderedSame
        }
        if isTaken {
            return ThemeLoadError.nameTaken(name).localizedDescription
        }
        return isEncodable(candidate) ? nil : ThemeLoadError.invalidName.localizedDescription
    }

    private func isEncodable(_ candidate: ThemeDefinition) -> Bool {
        (try? ThemeFileFormat.encode(candidate)) != nil
    }

    // MARK: - Undo

    /// A group of its own, so the step is one undo whether or not the manager groups by event. A
    /// window's manager does, and nests this in the event's group.
    private func registerUndo(restoring snapshot: ThemeDefinition, actionName: String) {
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.restore(snapshot, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()
    }

    /// Registering the current draft while undoing is what makes the step redoable.
    private func restore(_ snapshot: ThemeDefinition, actionName: String) {
        guard isEditable else { return }
        settlingSlot = nil
        registerUndo(restoring: draft, actionName: actionName)
        var next = snapshot
        next.id = draft.id
        commit(next)
    }

    // MARK: - Saving

    private func scheduleSave() {
        saveTask?.cancel()
        let clock = clock
        let delay = saveDelay
        saveTask = Task { [weak self] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.saveTask = nil
            self.save()
        }
    }

    /// Writes the draft now, with the text still being typed in Name or Author: quitting closes no
    /// window, so nothing else commits it. False when the write failed or a newer file took its place.
    @discardableResult
    internal func flush() -> Bool {
        commitName()
        commitAuthor()
        saveTask?.cancel()
        saveTask = nil
        return save()
    }

    @discardableResult
    private func save() -> Bool {
        settlingSlot = nil
        guard !isReadOnly, !isDetached, draft != lastSaved else { return true }
        if let listed = catalog.storedTheme(id: draft.id), listed != lastSaved {
            adoptNewerVersion(listed)
            return false
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try catalog.save(draft)
            let stored = catalog.storedTheme(id: draft.id) ?? draft
            lastSaved = stored
            fileURL = catalog.fileURL(for: draft.id)
            if stored != draft {
                showFields(of: stored, replacing: draft)
                draft = stored
                previewScope = .fixed(stored)
            }
            return true
        } catch let error as ThemeLoadError {
            handleSaveError(error)
            return false
        } catch {
            Self.logger.error("Theme save failed: \(error.publicLogShape, privacy: .public)")
            alert = .saveFailed(name: draft.name, reason: error.localizedDescription)
            return false
        }
    }

    private func handleSaveError(_ error: ThemeLoadError) {
        Self.logger.error("Theme save refused: \(error.publicLogShape, privacy: .public)")
        switch error {
        case .changedOnDisk:
            if let listed = catalog.storedTheme(id: draft.id) {
                adoptNewerVersion(listed)
            } else {
                detach(.unreadableOnDisk(name: draft.name))
            }
        case .deletedOnDisk:
            detach(.deletedOnDisk(name: draft.name))
        default:
            alert = .saveFailed(name: draft.name, reason: error.localizedDescription)
        }
    }

    // MARK: - Changes from elsewhere

    /// `@Published` sends before it stores, but the catalog stores the file's own definitions
    /// first, so the stored theme read here is already the new one. The shown list can rename a
    /// theme to tell two apart, which is not a change to its file.
    private func catalogWillPublish() {
        guard !isSaving, !isClosed, !isDetached else { return }
        guard let listed = catalog.storedTheme(id: draft.id) else {
            themeLeftTheCatalog()
            return
        }
        guard listed != lastSaved else { return }
        adoptNewerVersion(listed)
    }

    private func themeLeftTheCatalog() {
        saveTask?.cancel()
        saveTask = nil
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            detach(.unreadableOnDisk(name: draft.name))
        } else {
            detach(.deletedOnDisk(name: draft.name))
        }
    }

    /// The newer file wins, as the catalog's own conflict rule says. The undo steps describe the
    /// older version, so they go with it.
    private func adoptNewerVersion(_ listed: ThemeDefinition) {
        saveTask?.cancel()
        saveTask = nil
        settlingSlot = nil
        undoManager.removeAllActions(withTarget: self)
        showFields(of: listed, replacing: draft)
        draft = listed
        lastSaved = listed
        openingSnapshot = listed
        previewScope = .fixed(listed)
        preview.beginPreview(listed)
        alert = .changedOnDisk(name: listed.name)
    }

    private func detach(_ reason: Alert) {
        saveTask?.cancel()
        saveTask = nil
        settlingSlot = nil
        isDetached = true
        undoManager.removeAllActions(withTarget: self)
        preview.endPreview(id: draft.id)
        alert = reason
    }

    /// "Keep Theme" after the file was deleted elsewhere: the draft becomes a new theme with a new
    /// id, so a sync of that deletion cannot remove it again, and any slot that chose the old one
    /// follows it.
    internal func keepAsNewTheme() {
        guard isDetached, !isReadOnly else { return }
        let oldId = draft.id
        var kept = draft
        kept.id = ThemeIdentifier.generated()
        kept.name = catalog.uniqueName(kept.name)
        do {
            try catalog.save(kept)
        } catch {
            Self.logger.error("Keeping a deleted theme failed: \(error.publicLogShape, privacy: .public)")
            alert = .saveFailed(name: kept.name, reason: error.localizedDescription)
            return
        }
        let stored = catalog.storedTheme(id: kept.id) ?? kept
        isDetached = false
        showFields(of: stored, replacing: draft)
        draft = stored
        lastSaved = stored
        openingSnapshot = stored
        fileURL = catalog.fileURL(for: stored.id)
        previewScope = .fixed(stored)
        repointSelection(from: oldId, to: stored.id)
        onIdentifierChange?(oldId, stored.id)
    }

    private func repointSelection(from oldId: String, to newId: String) {
        guard let selection else { return }
        var updated = selection.themeSelection
        if updated.preferredLightThemeId == oldId { updated.preferredLightThemeId = newId }
        if updated.preferredDarkThemeId == oldId { updated.preferredDarkThemeId = newId }
        if updated != selection.themeSelection {
            selection.themeSelection = updated
        }
    }

    // MARK: - Closing

    internal func requestClose() {
        onRequestClose?()
    }

    /// A refused Name or Author keeps the window open with the reason under its field, the same rule
    /// as while editing. A write that fails asks first, because closing then loses the changes the
    /// alert names.
    internal func prepareToClose() -> CloseDecision {
        guard isEditable else { return .close }
        let nameOutcome = commitName()
        let isAuthorAccepted = commitAuthor()
        if case .rejected = nameOutcome {
            return .keepEditing
        }
        guard isAuthorAccepted else { return .keepEditing }
        saveTask?.cancel()
        saveTask = nil
        guard draft != lastSaved else { return .close }
        if let listed = catalog.storedTheme(id: draft.id), listed != lastSaved {
            return .close
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try catalog.save(draft)
            lastSaved = catalog.storedTheme(id: draft.id) ?? draft
            return .close
        } catch let error as ThemeLoadError where error.isConflict {
            return .close
        } catch {
            Self.logger.error("Theme save on close failed: \(error.publicLogShape, privacy: .public)")
            return .confirmDiscard(name: draft.name, reason: error.localizedDescription)
        }
    }

    internal func close() {
        guard !isClosed else { return }
        isClosed = true
        saveTask?.cancel()
        saveTask = nil
        catalogCancellable = nil
        undoManager.removeAllActions()
        preview.endPreview(id: draft.id)
    }
}

private extension ThemeLoadError {
    var isConflict: Bool {
        switch self {
        case .changedOnDisk, .deletedOnDisk: return true
        default: return false
        }
    }
}
