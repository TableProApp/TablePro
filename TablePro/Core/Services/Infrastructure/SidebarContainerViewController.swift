//
//  SidebarContainerViewController.swift
//  TablePro
//

import AppKit
import Combine
import SwiftUI

@MainActor
internal final class SidebarContainerViewController: NSViewController {
    /// Which list the rows below show. Window chrome like the field under it, so it stands through
    /// a connection switch and follows the connection on screen.
    private let scopeControl = SidebarScopeControl()
    private let searchField = NSSearchField()
    /// Sidebar chrome, like the field it shares a row with, so it survives a connection switch and
    /// writes settings that are not scoped to one. Hidden on the Favorites tab, whose list draws
    /// none of what these options settle.
    private let viewOptionsButton = SidebarViewOptionsButton()
    private lazy var filterRow = NSStackView(views: [searchField, viewOptionsButton])
    /// The filter field is window chrome and stays put; only the object list below it belongs to a
    /// connection, so that is the part the window swaps.
    private let listHost = WorkspacePaneHost()
    private var sidebarState: SharedSidebarState?
    private var observationTask: Task<Void, Never>?
    private var filterPopover: NSPopover?
    /// Exactly one of these is active. A hidden view keeps its constraints, so hiding the two rows
    /// alone would leave the list standing under their height.
    private var listBelowChrome: NSLayoutConstraint?
    private var listAtTop: NSLayoutConstraint?
    private var chromeHidden = false

    /// A list the user picked, reported to the window, which owns the sidebar and whether it is
    /// open.
    internal var onScopeSelection: ((SidebarTab) -> Void)?

    internal func show(_ controller: NSViewController?) {
        listHost.show(controller)
    }

    /// The pane below the chrome, for a caller that has to read back which one is drawn: the
    /// object browser, or Agent mode's session rail in its place.
    internal var shownPane: NSViewController? {
        listHost.shown
    }

    /// Which list the scope control has selected, for a caller that has to read the chrome back.
    internal var selectedScope: SidebarTab? {
        scopeControl.selectedTab
    }

    internal var isScopeEnabled: Bool {
        scopeControl.isEnabled
    }

    internal var isChromeHidden: Bool {
        chromeHidden
    }

    /// Agent mode puts its session rail where the object list goes, and neither row above it has
    /// anything there to act on: the scope would switch a list that is not drawn, and the field
    /// would filter one. Both go, and the rail takes their height.
    internal func setChromeHidden(_ hidden: Bool) {
        guard chromeHidden != hidden else { return }
        chromeHidden = hidden
        applyChromeVisibility()
    }

    /// Recorded before it is applied, so a mode that arrives before the view loads is still the
    /// one the view comes up in.
    private func applyChromeVisibility() {
        guard isViewLoaded else { return }
        scopeControl.isHidden = chromeHidden
        filterRow.isHidden = chromeHidden
        if chromeHidden {
            listBelowChrome?.isActive = false
            listAtTop?.isActive = true
        } else {
            listAtTop?.isActive = false
            listBelowChrome?.isActive = true
        }
    }

    /// Whether the filter field answers, and what it currently holds. The object list below it
    /// belongs to a connection; the field belongs to the window and stands whether or not one is
    /// up, so both of these have to be true of a window with no session as well as one with.
    internal var isFilterEnabled: Bool {
        searchField.isEnabled
    }

    internal var filterText: String {
        searchField.stringValue
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

        scopeControl.translatesAutoresizingMaskIntoConstraints = false
        /// Standing and dimmed until a connection is up, for the reason the field below it is.
        scopeControl.isEnabled = false
        scopeControl.target = self
        scopeControl.action = #selector(scopeChanged(_:))
        view.addSubview(scopeControl)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        /// Standing from the window's first frame, disabled until a connection is up. It used to
        /// be hidden until then, so the sidebar was a bare column for the length of a connect and
        /// the field arrived with the object list. The HIG's answer to a control that does not
        /// apply yet is to dim it, not to take it away.
        searchField.isEnabled = false
        searchField.placeholderString = String(localized: "Filter")
        searchField.controlSize = .regular
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.setAccessibilityIdentifier("sidebar-filter")
        searchField.setAccessibilityLabel(String(localized: "Filter"))

        viewOptionsButton.isHidden = true
        viewOptionsButton.setContentHuggingPriority(.required, for: .horizontal)

        /// A stack view rather than two anchored controls, so hiding the button on the Favorites
        /// tab takes its width with it: `detachesHiddenViews` removes a hidden arranged subview
        /// from the layout, where a hidden anchored one would keep its gap beside the field.
        filterRow.translatesAutoresizingMaskIntoConstraints = false
        filterRow.orientation = .horizontal
        filterRow.alignment = .centerY
        filterRow.spacing = 6
        filterRow.detachesHiddenViews = true
        view.addSubview(filterRow)

        addChild(listHost)
        let hostingView = listHost.view
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingView)

        /// The insets are a margin, not an invariant, so they yield rather than break when the
        /// window narrows the sidebar to the workspace rail and leaves this view no width at all.
        let insets = [
            scopeControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            scopeControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            filterRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            filterRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
        ]
        for inset in insets {
            inset.priority = .defaultHigh
        }
        let listBelowChrome = hostingView.topAnchor.constraint(equalTo: filterRow.bottomAnchor, constant: 5)
        self.listBelowChrome = listBelowChrome
        listAtTop = hostingView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)

        NSLayoutConstraint.activate(insets + [
            scopeControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 5),
            filterRow.topAnchor.constraint(equalTo: scopeControl.bottomAnchor, constant: 6),

            listBelowChrome,
            hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        applyChromeVisibility()
    }

    /// Asked of the field's ancestors too, because Agent mode hides the row it sits in rather
    /// than the field itself, and focusing a field nobody can see puts the keyboard nowhere.
    func focusSearchField() {
        guard !searchField.isHiddenOrHasHiddenAncestor else { return }
        view.window?.makeFirstResponder(searchField)
    }

    /// The list under the filter field, whichever list that currently is: the object tree in any of
    /// its layouts, or the favorites list. Both subclass `SidebarOutlineView`, and only the mounted
    /// one is in the subtree, so the tab the user is on needs no tracking of its own.
    @discardableResult
    func focusObjectList() -> Bool {
        guard let outlineView = mountedObjectList, let window = view.window else { return false }
        return window.makeFirstResponder(outlineView)
    }

    var hasObjectList: Bool {
        mountedObjectList != nil
    }

    private var mountedObjectList: SidebarOutlineView? {
        listHost.view.firstDescendant(of: SidebarOutlineView.self)
    }

    /// The database filter, shown from the View menu and from the object list's contextual menu
    /// rather than from a button at the bottom of the sidebar. It anchors on the filter field
    /// because that is what it scopes, and because the field is the one piece of sidebar chrome
    /// that outlives a workspace switch.
    func presentDatabaseFilter(connectionId: UUID, sidebarState: SharedSidebarState) {
        guard !searchField.isHiddenOrHasHiddenAncestor else { return }
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
            /// `syncFromState` is the only writer of these, and it cannot run without a state, so
            /// the field would otherwise keep the filter text of the connection it just left.
            searchField.isEnabled = false
            searchField.stringValue = ""
            searchField.placeholderString = String(localized: "Filter")
            searchField.setAccessibilityLabel(String(localized: "Filter"))
            viewOptionsButton.isHidden = true
            scopeControl.isEnabled = false
            scopeControl.selectedTab = nil
            return
        }
        searchField.isEnabled = true
        scopeControl.isEnabled = true
        /// Set here rather than left to the observation task, which runs on the next main-actor
        /// turn: the button would show over the favorites filter for a turn on the way in, and
        /// linger for a turn on the way out, with the stack view re-laying the row each time. The
        /// scope follows for the same reason, or it would name the previous connection's list.
        viewOptionsButton.isHidden = state.selectedSidebarTab != .tables
        scopeControl.selectedTab = state.selectedSidebarTab
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
                /// One-shot: the continuation resumes on the first change, and the sink is
                /// released with the box, so nothing needs re-arming.
                box.hold(state.onMainActorChange {
                    box.resume()
                })
            }
        } onCancel: {
            box.resume()
        }
    }

    deinit {
        observationTask?.cancel()
    }

    /// Every later change to the list choice arrives here, so View > Show Tables and Show
    /// Favorites, which write the same state the scope control does, move the control with them.
    private func syncFromState(_ state: SharedSidebarState) {
        scopeControl.selectedTab = state.selectedSidebarTab
        let activeText: String
        let placeholder: String
        switch state.selectedSidebarTab {
        case .tables:
            activeText = state.searchText
            placeholder = String(localized: "Filter")
            viewOptionsButton.isHidden = false
        case .favorites:
            activeText = state.favoritesSearchText
            placeholder = String(localized: "Filter favorites")
            viewOptionsButton.isHidden = true
        }

        if searchField.stringValue != activeText {
            searchField.stringValue = activeText
        }
        searchField.placeholderString = placeholder
        searchField.setAccessibilityLabel(placeholder)
    }

    /// Only a change reaches the window. `NSSegmentedControl` sends its action for a click on the
    /// segment that is already selected as well, measured on macOS 27, and the command it drives
    /// collapses the sidebar on a second press of the list it is showing. From a control inside the
    /// sidebar that would take the control away with the pane it sits in.
    @objc private func scopeChanged(_ sender: SidebarScopeControl) {
        guard let tab = sender.selectedTab, tab != sidebarState?.selectedSidebarTab else { return }
        onScopeSelection?(tab)
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

    /// Down from the filter field hands focus to the list.
    ///
    /// It names the list rather than asking the key view loop for whatever comes next. With the
    /// system's Keyboard Navigation on, the view options button beside the field is a key view too,
    /// so `selectKeyView(following:)` lands there and Down stops reaching the list on exactly the
    /// machines most likely to press it. Returning false when nothing took focus leaves AppKit's own
    /// handling in place.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.moveDown(_:)) else { return false }
        return focusObjectList()
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
    private var observation: AnyCancellable?

    /// Keeps the subscription alive until the continuation resumes. `withObservationTracking`
    /// needed nothing here because it fired once and released itself.
    func hold(_ cancellable: AnyCancellable) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        observation = cancellable
    }

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
        observation = nil
        resumed = true
        continuation?.resume()
        continuation = nil
    }
}
