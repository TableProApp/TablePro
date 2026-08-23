//
//  SidebarContainerViewController.swift
//  TablePro
//

import AppKit
import SwiftUI

@MainActor
internal final class SidebarContainerViewController: NSViewController {
    private let searchField = NSSearchField()
    /// The filter field is window chrome and stays put; only the object list below it belongs to a
    /// connection, so that is the part the window swaps.
    private let listHost = WorkspacePaneHost()
    private var sidebarState: SharedSidebarState?
    private var observationTask: Task<Void, Never>?
    private var filterPopover: NSPopover?

    internal func show(_ controller: NSViewController?) {
        listHost.show(controller)
        searchField.nextKeyView = controller?.view ?? listHost.view
    }

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SidebarContainerViewController does not support NSCoder init")
    }

    override func loadView() {
        view = NSView()

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.isHidden = true
        searchField.placeholderString = String(localized: "Filter")
        searchField.controlSize = .regular
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.setAccessibilityIdentifier("sidebar-filter")
        searchField.setAccessibilityLabel(String(localized: "Filter"))
        view.addSubview(searchField)

        addChild(listHost)
        let hostingView = listHost.view
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingView)
        searchField.nextKeyView = hostingView

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 5),
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),

            hostingView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 5),
            hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func focusSearchField() {
        guard !searchField.isHidden else { return }
        view.window?.makeFirstResponder(searchField)
    }

    /// The database filter, shown from the View menu and from the object list's contextual menu
    /// rather than from a button at the bottom of the sidebar. It anchors on the filter field
    /// because that is what it scopes, and because the field is the one piece of sidebar chrome
    /// that outlives a workspace switch.
    func presentDatabaseFilter(connectionId: UUID, sidebarState: SharedSidebarState) {
        guard !searchField.isHidden else { return }
        filterPopover?.close()
        filterPopover = PopoverPresenter.show(
            relativeTo: searchField.bounds,
            of: searchField,
            preferredEdge: .maxY,
            behavior: .transient
        ) { _ in
            DatabaseTreeFilterPopover(
                connectionId: connectionId,
                selectedDatabases: Binding(
                    get: { sidebarState.databaseFilterSelected },
                    set: { sidebarState.databaseFilterSelected = $0 }
                )
            )
        }
    }

    func updateSidebarState(_ state: SharedSidebarState?) {
        observationTask?.cancel()
        /// The popover is scoped to the connection whose databases it lists, and this is the field
        /// being repointed at a different one.
        filterPopover?.close()
        filterPopover = nil
        self.sidebarState = state
        guard let state else {
            searchField.isHidden = true
            return
        }
        searchField.isHidden = false
        observationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.syncFromState(state)
                await Self.awaitChange(state: state)
            }
        }
    }

    private static func awaitChange(state: SharedSidebarState) async {
        let box = ObservationContinuationBox()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                box.attach(continuation)
                withObservationTracking {
                    _ = state.selectedSidebarTab
                    _ = state.searchText
                    _ = state.favoritesSearchText
                } onChange: {
                    box.resume()
                }
            }
        } onCancel: {
            box.resume()
        }
    }

    deinit {
        observationTask?.cancel()
    }

    private func syncFromState(_ state: SharedSidebarState) {
        let activeText: String
        let placeholder: String
        switch state.selectedSidebarTab {
        case .tables:
            activeText = state.searchText
            placeholder = String(localized: "Filter")
        case .favorites:
            activeText = state.favoritesSearchText
            placeholder = String(localized: "Filter favorites")
        }

        if searchField.stringValue != activeText {
            searchField.stringValue = activeText
        }
        searchField.placeholderString = placeholder
        searchField.setAccessibilityLabel(placeholder)
    }
}

extension SidebarContainerViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField else { return }
        writeSearchText(field.stringValue)
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        writeSearchText("")
    }

    /// Down from the filter field hands focus to the list. The handoff goes through the key view loop,
    /// which only ever lands on a view that answers `acceptsFirstResponder`; naming the hosting view
    /// directly parked focus on a view that does not, so the selection never moved, the list never drew
    /// as focused, and returning true swallowed the key. Returning false when nothing took focus leaves
    /// AppKit's own handling in place.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.moveDown(_:)), let window = view.window else {
            return false
        }
        let previous = window.firstResponder
        window.selectKeyView(following: searchField)
        return window.firstResponder !== previous
    }

    private func writeSearchText(_ text: String) {
        guard let sidebarState else { return }
        switch sidebarState.selectedSidebarTab {
        case .tables:
            sidebarState.searchText = text
        case .favorites:
            sidebarState.favoritesSearchText = text
        }
    }
}

private final class ObservationContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var resumed = false

    func attach(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else {
            continuation.resume()
            return
        }
        self.continuation = continuation
    }

    func resume() {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation?.resume()
        continuation = nil
    }
}
