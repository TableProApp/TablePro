//
//  ConnectionEditorWindowController.swift
//  TablePro
//

import AppKit
import Combine

// Where the editor opens. Never part of the request: one connection keeps one window whatever facet asked for it.
enum ConnectionEditorFacetChoice: Equatable {
    case named(ConnectionFacet)
    // The facet of the first issue that blocks Save: what a connect refused over its own settings points at.
    case firstIssue
}

// Hosts the connection editor in an AppKit window, so the app needs no SwiftUI scene for it. The registry
// keyed by request keeps one window per edited connection: two would each save over the other.
@MainActor
final class ConnectionEditorWindowController: NSWindowController, NSWindowDelegate {
    private static var controllers: [ConnectionFormRequest: ConnectionEditorWindowController] = [:]
    private static let cascadeOffset: CGFloat = 22

    let store: ConnectionEditorStore
    let content: ConnectionEditorViewController
    private let toolbarController: ConnectionEditorToolbar
    private let frameAutosaveName: String?
    private var storeObservation: AnyCancellable?

    var sidebar: ConnectionEditorSidebarViewController { content.split.sidebar }
    var detail: ConnectionEditorDetailViewController { content.split.detail }

    // A window already open for the request only moves when the caller names where.
    static func present(_ request: ConnectionFormRequest, facet: ConnectionEditorFacetChoice? = nil) {
        if let existing = controllers[request] {
            existing.open(on: facet)
            existing.showAndActivate()
            return
        }
        let controller = ConnectionEditorWindowController(
            store: ConnectionEditorStore(request: storeRequest(for: request)),
            facet: facet,
            frameAutosaveName: SplitViewAutosaveName.current(ConnectionEditorWindowFrame.autosaveName)
        )
        controller.cascade(from: controllers.values.compactMap(\.window))
        controllers[request] = controller
        controller.showAndActivate()
    }

    private static func storeRequest(for request: ConnectionFormRequest) -> ConnectionEditorStore.Request {
        switch request {
        case .edit(let connectionId):
            return .edit(connectionId: connectionId)
        case .create(let draftId):
            // Read once: consume removes the draft, so a second read would drop its parsed URL.
            let draft = ConnectionFormDraftStore.shared.consume(draftId)
            return .new(type: draft?.type, parsedURL: draft?.parsedURL)
        }
    }

    init(store: ConnectionEditorStore, facet: ConnectionEditorFacetChoice? = nil, frameAutosaveName: String?) {
        self.store = store
        self.frameAutosaveName = frameAutosaveName
        // Before the content loads, so the first facet built is the one shown.
        ConnectionEditorWindowController.select(facet, in: store)
        let relay = ControllerRelay()
        let content = ConnectionEditorViewController(
            store: store,
            actions: ConnectionEditorCommitActions(
                test: { relay.controller?.runTest() },
                save: { relay.controller?.save() },
                commit: { relay.controller?.commit() },
                cancel: { relay.controller?.requestClose() },
                copyURL: { relay.controller?.copyURL() },
                delete: { relay.controller?.confirmDelete() }
            ),
            onCloseMissingRecord: { relay.controller?.requestClose() }
        )
        self.content = content

        let window = NSWindow(contentViewController: content)
        let toolbarController = ConnectionEditorToolbar(splitView: content.split.splitView)
        self.toolbarController = toolbarController
        window.identifier = NSUserInterfaceItemIdentifier(WindowIdentifier.connectionForm)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.keepsKeyViewLoopCurrent()
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert([.fullScreenNone, .fullScreenDisallowsTiling])
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        window.toolbar = toolbarController.makeToolbar()
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        ConnectionEditorWindowFrame.apply(to: window, autosaveName: frameAutosaveName)

        super.init(window: window)
        relay.controller = self
        window.delegate = self
        store.window = window
        store.dismissAction = { [weak self] in self?.close() }
        storeObservation = store.onMainActorChange { [weak self] in
            self?.syncChrome()
        }
        syncChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ConnectionEditorWindowController does not support NSCoder init")
    }

    func open(on facet: ConnectionEditorFacetChoice?) {
        guard window?.attachedSheet == nil else { return }
        Self.select(facet, in: store)
        syncChrome()
    }

    private static func select(_ facet: ConnectionEditorFacetChoice?, in store: ConnectionEditorStore) {
        guard let facet, !store.isRecordMissing else { return }
        switch facet {
        case .named(let facet):
            guard store.layout.facetIDs.contains(facet) else { return }
            store.selectedFacet = facet
        case .firstIssue:
            guard let issue = store.firstBlockingIssue else { return }
            store.focus(on: issue)
        }
    }

    func showAndActivate() {
        if window?.isMiniaturized == true {
            window?.deminiaturize(nil)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        AppActivationPolicyController.shared.activate()
    }

    private func cascade(from others: [NSWindow]) {
        guard let window, let anchor = others.last(where: { $0.isVisible }) else { return }
        var frame = window.frame
        frame.origin = NSPoint(
            x: anchor.frame.minX + Self.cascadeOffset,
            y: anchor.frame.maxY - Self.cascadeOffset - frame.height
        )
        window.setFrame(window.constrainFrameRect(frame, to: anchor.screen), display: false)
    }

    // The one place store state reaches the window: title, subtitle, edited dot, sidebar and detail.
    func syncChrome() {
        let title = store.windowTitle
        if content.title != title {
            content.title = title
        }
        if let window {
            let subtitle = store.windowSubtitle
            if window.subtitle != subtitle {
                window.subtitle = subtitle
            }
            let isEdited = store.hasUnsavedChanges && !store.isRecordMissing
            if window.isDocumentEdited != isEdited {
                window.isDocumentEdited = isEdited
            }
        }
        content.split.sync()
    }

    // MARK: - Commands

    // Commits a field still being edited, so a half-typed value is what Save, Test or the close check see.
    private func endEditing() -> Bool {
        guard let window else { return true }
        return window.makeFirstResponder(nil)
    }

    func runTest() {
        guard endEditing() else { return }
        if store.isTesting {
            store.cancelTest()
        } else {
            store.test()
        }
    }

    func save() {
        guard endEditing() else { return }
        store.save(connect: false)
    }

    // Save & Connect for a new connection, Save for an edited one; success closes the window.
    func commit() {
        guard endEditing() else { return }
        store.commit()
    }

    func copyURL() {
        _ = endEditing()
        ClipboardService.shared.writeText(store.connectionURLForCopy())
    }

    func confirmDelete() {
        guard store.canDelete else { return }
        Task { [weak self] in
            guard let self else { return }
            let confirmation = await store.deleteConfirmation()
            let confirmed = await AlertHelper.confirmDestructive(
                title: confirmation.title,
                message: confirmation.message,
                confirmButton: String(localized: "Delete"),
                window: window
            )
            guard confirmed else { return }
            store.delete()
        }
    }

    // MARK: - Closing

    var closeVerdict: ConnectionEditorCloseGuard.Verdict {
        ConnectionEditorCloseGuard.verdict(
            hasUnsavedChanges: store.hasUnsavedChanges,
            isRecordMissing: store.isRecordMissing,
            connectionName: store.windowTitle
        )
    }

    // Cancel and Escape: the same question the close button asks.
    func requestClose() {
        guard window?.attachedSheet == nil, endEditing() else { return }
        switch closeVerdict {
        case .close:
            close()
        case .askToSave(let prompt):
            askToSave(prompt)
        }
    }

    func resolveClose(_ choice: ConnectionEditorCloseGuard.Choice) {
        switch choice {
        case .save:
            // Closes through dismissAction only when the save lands; a failure keeps the window and says why.
            commit()
        case .dontSave:
            close()
        case .cancel:
            break
        }
    }

    private func askToSave(_ prompt: ConnectionEditorSavePrompt) {
        guard let window, window.attachedSheet == nil else { return }
        AlertHelper.present(ConnectionEditorCloseGuard.makeAlert(prompt), in: window) { [weak self] response in
            self?.resolveClose(ConnectionEditorCloseGuard.choice(for: response))
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        _ = endEditing()
        switch closeVerdict {
        case .close:
            return true
        case .askToSave(let prompt):
            askToSave(prompt)
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let window {
            ConnectionEditorWindowFrame.save(window, autosaveName: frameAutosaveName)
        }
        storeObservation = nil
        store.teardown()
        Self.controllers = Self.controllers.filter { $0.value !== self }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window else { return }
        ConnectionEditorWindowFrame.save(window, autosaveName: frameAutosaveName)
    }

    func windowDidMove(_ notification: Notification) {
        guard let window, window.isVisible else { return }
        ConnectionEditorWindowFrame.save(window, autosaveName: frameAutosaveName)
    }

    // File > Save, Cmd+S: saves without connecting, also for a new connection.
    @objc func saveDocument(_ sender: Any?) {
        save()
    }
}

extension ConnectionEditorWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(saveDocument(_:)):
            return store.canSave && window?.attachedSheet == nil
        default:
            return true
        }
    }
}

// The commit bar's actions are built before the controller exists, so they reach it through this.
@MainActor
private final class ControllerRelay {
    weak var controller: ConnectionEditorWindowController?
}
