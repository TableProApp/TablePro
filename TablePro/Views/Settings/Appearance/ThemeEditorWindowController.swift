import AppKit
import Combine
import os
import SwiftUI
import TableProTheme

/// The open Theme Editor windows, one per theme. Opening a theme that already has a window brings
/// that window forward instead of making a second editor that could save over the first.
@MainActor
internal final class ThemeEditorWindows: ThemeEditorPresenting {
    internal static let shared = ThemeEditorWindows(
        catalog: .shared,
        preview: ThemeEngine.shared,
        selection: AppSettingsManager.shared
    )

    private let catalog: ThemeCatalog
    private let preview: ThemePreviewing
    private let selection: ThemeSelectionStore?
    private var controllers: [String: ThemeEditorWindowController] = [:]
    private var terminationObserver: NSObjectProtocol?
    private let confirmQuitWithoutSaving: @MainActor (_ name: String, _ reason: String) -> Bool

    private static let logger = Logger(subsystem: "com.TablePro", category: "ThemeEditorWindows")

    internal init(
        catalog: ThemeCatalog,
        preview: ThemePreviewing,
        selection: ThemeSelectionStore?,
        notificationCenter: NotificationCenter = .default,
        confirmQuitWithoutSaving: @escaping @MainActor (_ name: String, _ reason: String) -> Bool = ThemeEditorWindows.askToQuitWithoutSaving
    ) {
        self.catalog = catalog
        self.preview = preview
        self.selection = selection
        self.confirmQuitWithoutSaving = confirmQuitWithoutSaving
        // A window closed by quitting never asks to close, so its pending save is written here.
        terminationObserver = notificationCenter.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushAll()
            }
        }
    }

    internal var openThemeIds: Set<String> {
        Set(controllers.keys)
    }

    internal func controller(for themeId: String) -> ThemeEditorWindowController? {
        controllers[themeId]
    }

    internal func openEditor(for themeId: String) {
        if let existing = controllers[themeId] {
            existing.present()
            return
        }
        guard let theme = catalog.storedTheme(id: themeId) else {
            Self.logger.error("No theme \(themeId, privacy: .public) to edit")
            return
        }
        let model = ThemeEditorModel(theme: theme, catalog: catalog, preview: preview, selection: selection)
        let controller = ThemeEditorWindowController(model: model, windows: self)
        controllers[themeId] = controller
        controller.present()
    }

    internal func editor(for themeId: String) -> ThemeEditorModel? {
        controllers[themeId]?.model
    }

    internal func closeEditor(for themeId: String) {
        controllers[themeId]?.closeKeepingChanges()
    }

    /// A built-in theme is read-only, so its window offers a copy and hands over to the copy's.
    internal func duplicate(from controller: ThemeEditorWindowController) {
        let source = controller.model.draft
        do {
            let copy = try catalog.duplicate(source)
            openEditor(for: copy.id)
            controller.closeKeepingChanges()
        } catch {
            Self.logger.error("Duplicating a theme failed: \(error.publicLogShape, privacy: .public)")
            controller.model.alert = .saveFailed(name: source.name, reason: error.localizedDescription)
        }
    }

    fileprivate func identifierChanged(from oldId: String, to newId: String, controller: ThemeEditorWindowController) {
        guard controllers[oldId] === controller else { return }
        controllers[oldId] = nil
        controllers[newId] = controller
    }

    fileprivate func didClose(_ controller: ThemeEditorWindowController) {
        controllers = controllers.filter { $0.value !== controller }
    }

    private func flushAll() {
        for controller in controllers.values {
            controller.model.flush()
        }
    }

    /// Asked from `applicationShouldTerminate`, before quitting is approved: a save that fails or a
    /// refused name has to stop the quit, which the termination notification is too late to do.
    internal func prepareToTerminate() -> Bool {
        for controller in controllers.values {
            switch controller.model.prepareToClose() {
            case .close:
                continue
            case .keepEditing:
                controller.present()
                NSSound.beep()
                return false
            case let .confirmDiscard(name, reason):
                controller.present()
                guard confirmQuitWithoutSaving(name, reason) else { return false }
            }
        }
        return true
    }

    internal static func askToQuitWithoutSaving(name: String, reason: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: String(localized: "Couldn't Save “%@”"), name)
        alert.informativeText = reason
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Quit Without Saving"))
        return alert.runModal() == .alertSecondButtonReturn
    }
}

/// A non-modal window for one theme: title the theme's name, proxy icon its file, Edit menu undo
/// through the model's undo manager. The window is chrome; only its preview wears the theme.
@MainActor
internal final class ThemeEditorWindowController: NSWindowController, NSWindowDelegate {
    internal let model: ThemeEditorModel

    private weak var windows: ThemeEditorWindows?
    private var cancellables: Set<AnyCancellable> = []
    private var isCloseConfirmed = false

    private static let contentSize = NSSize(width: 640, height: 700)
    private static let minimumSize = NSSize(width: 520, height: 480)
    private static var lastTopLeft: NSPoint?

    internal init(model: ThemeEditorModel, windows: ThemeEditorWindows) {
        self.model = model
        self.windows = windows
        super.init(window: nil)

        // The delegate goes in before the content: a window whose undo manager was read while it had
        // no delegate keeps that manager and never asks for the model's.
        let window = ThemeEditorWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)
        window.title = model.draft.name
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.keepsKeyViewLoopCurrent()
        window.contentMinSize = Self.minimumSize

        let hosting = NSHostingController(rootView: ThemeEditorView(model: model) { [weak self] in
            guard let self else { return }
            self.windows?.duplicate(from: self)
        })
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(Self.contentSize)
        window.representedURL = model.fileURL
        self.window = window

        placeWindow(window)
        observeModel(window: window)
    }

    @available(*, unavailable)
    internal required init?(coder: NSCoder) {
        fatalError("ThemeEditorWindowController does not support NSCoder init")
    }

    internal static let windowIdentifier = "theme-editor"

    internal func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        AppActivationPolicyController.shared.activate()
        // SwiftUI can mount the preview after the window first becomes key.
        DispatchQueue.main.async { [weak self] in
            self?.releasePreviewFocus()
        }
    }

    /// Closing from the list: the draft is written first, and nothing asks.
    internal func closeKeepingChanges() {
        model.flush()
        isCloseConfirmed = true
        window?.close()
    }

    private func placeWindow(_ window: NSWindow) {
        if let topLeft = Self.lastTopLeft {
            Self.lastTopLeft = window.cascadeTopLeft(from: topLeft)
        } else {
            window.center()
            Self.lastTopLeft = window.cascadeTopLeft(from: NSPoint(x: window.frame.minX, y: window.frame.maxY))
        }
    }

    private func observeModel(window: NSWindow) {
        model.$draft
            .map(\.name)
            .removeDuplicates()
            .sink { [weak window] name in window?.title = name }
            .store(in: &cancellables)
        model.$fileURL
            .removeDuplicates()
            .sink { [weak window] url in window?.representedURL = url }
            .store(in: &cancellables)
        model.onRequestClose = { [weak self] in
            self?.isCloseConfirmed = true
            self?.window?.close()
        }
        model.onIdentifierChange = { [weak self] oldId, newId in
            guard let self else { return }
            self.windows?.identifierChanged(from: oldId, to: newId, controller: self)
        }
    }

    // MARK: - NSWindowDelegate

    internal func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        model.undoManager
    }

    internal func windowDidBecomeKey(_ notification: Notification) {
        releasePreviewFocus()
    }

    /// AppKit hands a new window's focus to its first key view, which is in the preview, and the
    /// preview's editor and grid answer Undo with histories of their own.
    private func releasePreviewFocus() {
        guard let window, let responder = window.firstResponder as? NSView, responder.isInsideThemePreview else { return }
        window.makeFirstResponder(nil)
    }

    internal func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isCloseConfirmed else { return true }
        switch model.prepareToClose() {
        case .close:
            return true
        case .keepEditing:
            return false
        case let .confirmDiscard(name, reason):
            confirmDiscard(name: name, reason: reason, in: sender)
            return false
        }
    }

    internal func windowWillClose(_ notification: Notification) {
        deactivateColorWells()
        model.close()
        windows?.didClose(self)
    }

    private func confirmDiscard(name: String, reason: String, in window: NSWindow) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: String(localized: "Couldn't Save “%@”"), name)
        alert.informativeText = reason
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Close Without Saving"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            self?.isCloseConfirmed = true
            self?.window?.close()
        }
    }

    /// The shared color panel keeps sending to an active well after its window is gone.
    private func deactivateColorWells() {
        guard let root = window?.contentView else { return }
        var pending: [NSView] = [root]
        while let view = pending.popLast() {
            if let well = view as? NSColorWell, well.isActive {
                well.deactivate()
            }
            pending.append(contentsOf: view.subviews)
        }
    }
}

/// Tab and Shift-Tab pass over the preview the way clicks do. Its editor and grid are key views in
/// AppKit's loop, and each answers Undo with an empty history of its own; they cannot be taken out
/// of the loop without losing the caret and selection they preview.
private final class ThemeEditorWindow: NSWindow {
    override func selectKeyView(following view: NSView) {
        super.selectKeyView(following: view)
        passOverPreview { super.selectKeyView(following: $0) }
    }

    override func selectKeyView(preceding view: NSView) {
        super.selectKeyView(preceding: view)
        passOverPreview { super.selectKeyView(preceding: $0) }
    }

    private func passOverPreview(_ step: (NSView) -> Void) {
        var visited: Set<ObjectIdentifier> = []
        while let view = firstResponder as? NSView, view.isInsideThemePreview {
            guard visited.insert(ObjectIdentifier(view)).inserted else {
                makeFirstResponder(nil)
                return
            }
            step(view)
        }
    }
}
