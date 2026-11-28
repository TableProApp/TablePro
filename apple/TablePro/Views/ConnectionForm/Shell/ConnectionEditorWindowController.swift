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
    private var keyMonitor: Any?

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
        case .editTeamCopy(let teamID, let itemID):
            return .editTeamCopy(TeamCopyEditStage.shared.consume(teamID: teamID, itemID: itemID))
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
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] nsEvent in
            nonisolated(unsafe) let event = nsEvent
            let consumed = MainActor.assumeIsolated { self?.consumesKeyDown(event) ?? false }
            return consumed ? nil : nsEvent
        }
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
            connectionName: store.windowTitle,
            blockingIssue: store.canSave ? nil : store.firstBlockingIssue?.message
        )
    }

    // The Cancel button answers Escape as a key equivalent before a text view sees the key, so the edit is ended here
    // instead; an Escape with no field being edited reaches Cancel and its close guard.
    func consumesKeyDown(_ event: NSEvent) -> Bool {
        guard let window, ConnectionEditorEscape.endsEditing(event, in: window) else { return false }
        _ = endEditing()
        return true
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
            // Never connects, as Cmd+S: the person asked to save and close. A failed save keeps the window and says why.
            save()
        case .dontSave:
            close()
        case .cancel:
            revealWhatBlocksSave()
        }
    }

    // Staying after the alert said Save is blocked means fixing it, so the editor goes to the issue.
    private func revealWhatBlocksSave() {
        guard !store.canSave, let issue = store.firstBlockingIssue else { return }
        store.reveal(issue)
    }

    private func askToSave(_ prompt: ConnectionEditorSavePrompt) {
        guard let window, window.attachedSheet == nil else { return }
        AlertHelper.present(ConnectionEditorCloseGuard.makeAlert(prompt), in: window) { [weak self] response in
            self?.resolveClose(ConnectionEditorCloseGuard.choice(for: response, canSave: prompt.canSave))
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
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
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

    // MARK: - Quitting

    // Asked before anything else a quit stops, so Cancel here leaves the app as it was.
    static func prepareToTerminate(
        _ editors: [ConnectionEditorWindowController]? = nil,
        ask: @MainActor (ConnectionEditorWindowController, ConnectionEditorSavePrompt) -> ConnectionEditorCloseGuard.Choice
            = { editor, prompt in
                editor.showAndActivate()
                return editor.askToSaveModally(prompt)
            }
    ) -> Bool {
        for editor in editors ?? openEditorsFrontToBack {
            guard editor.approvesTermination(ask: ask) else { return false }
        }
        return true
    }

    // The quit skips windowShouldClose, so each editor is closed here to reap what a running test staged.
    static func closeAllForTermination() {
        for controller in Array(controllers.values) {
            controller.close()
        }
    }

    private static var openEditorsFrontToBack: [ConnectionEditorWindowController] {
        let order = NSApp.orderedWindows
        return controllers.values.sorted { lhs, rhs in
            let left = lhs.window.flatMap { order.firstIndex(of: $0) } ?? order.count
            let right = rhs.window.flatMap { order.firstIndex(of: $0) } ?? order.count
            return left < right
        }
    }

    // Save never connects here: the app is about to quit. A Save that fails keeps the window and stops the quit.
    func approvesTermination(
        ask: @MainActor (ConnectionEditorWindowController, ConnectionEditorSavePrompt) -> ConnectionEditorCloseGuard.Choice
    ) -> Bool {
        if window?.attachedSheet != nil {
            showAndActivate()
            NSSound.beep()
            return false
        }
        _ = endEditing()
        guard case .askToSave(let prompt) = closeVerdict else { return true }
        switch ask(self, prompt) {
        case .save:
            if case .success = store.save(connect: false) { return true }
            return false
        case .dontSave:
            return true
        case .cancel:
            revealWhatBlocksSave()
            return false
        }
    }

    func askToSaveModally(_ prompt: ConnectionEditorSavePrompt) -> ConnectionEditorCloseGuard.Choice {
        // A quit can come from outside the app, and a background process has no Dock icon to reach the alert by.
        AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
        let response = ConnectionEditorCloseGuard.makeAlert(prompt).runModal()
        return ConnectionEditorCloseGuard.choice(for: response, canSave: prompt.canSave)
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
