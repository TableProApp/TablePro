//
//  SidebarContainerViewController.swift
//  TablePro
//

import AppKit
import SwiftUI

@MainActor
internal final class SidebarContainerViewController: NSViewController {
    private let searchField = NSSearchField()
    private var hostingController: NSHostingController<AnyView>
    private var sidebarState: SharedSidebarState?
    private var windowState: WindowSidebarState?
    private var observationGeneration = 0

    var onOpenTable: ((TableInfo) -> Void)?

    var rootView: AnyView {
        get { hostingController.rootView }
        set { hostingController.rootView = newValue }
    }

    init(rootView: AnyView) {
        self.hostingController = NSHostingController(rootView: rootView)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SidebarContainerViewController does not support NSCoder init")
    }

    override func loadView() {
        view = NSView()

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = String(localized: "Filter")
        searchField.controlSize = .regular
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.setAccessibilityIdentifier("sidebar-filter")
        view.addSubview(searchField)

        addChild(hostingController)
        let hostingView = hostingController.view
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingView)

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

    func updateSidebarState(_ state: SharedSidebarState?, windowState: WindowSidebarState?) {
        observationGeneration += 1
        self.sidebarState = state
        self.windowState = windowState
        guard let state, let windowState else {
            searchField.isHidden = true
            return
        }
        searchField.isHidden = false
        syncFromState(state, windowState: windowState)
        startObserving(state, windowState: windowState, generation: observationGeneration)
    }

    private func startObserving(
        _ state: SharedSidebarState,
        windowState: WindowSidebarState,
        generation: Int
    ) {
        withObservationTracking {
            _ = state.selectedSidebarTab
            _ = windowState.searchText
            _ = windowState.favoritesSearchText
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      generation == self.observationGeneration,
                      let sidebarState = self.sidebarState,
                      let windowState = self.windowState else { return }
                self.syncFromState(sidebarState, windowState: windowState)
                self.startObserving(sidebarState, windowState: windowState, generation: generation)
            }
        }
    }

    private func syncFromState(_ state: SharedSidebarState, windowState: WindowSidebarState) {
        let activeText: String
        let placeholder: String
        switch state.selectedSidebarTab {
        case .tables:
            activeText = windowState.searchText
            placeholder = String(localized: "Filter")
        case .favorites:
            activeText = windowState.favoritesSearchText
            placeholder = String(localized: "Filter favorites")
        }

        if searchField.stringValue != activeText {
            searchField.stringValue = activeText
        }
        searchField.placeholderString = placeholder
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

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let sidebarState, sidebarState.selectedSidebarTab == .tables else { return false }

        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            navigateSelection(direction: -1)
            return true
        }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            navigateSelection(direction: 1)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if let selected = sidebarState.selectedTables.first {
                onOpenTable?(selected)
            }
            return true
        }
        return false
    }

    private func navigateSelection(direction: Int) {
        guard let sidebarState, let windowState else { return }
        let allTables = SchemaService.shared.tables(for: sidebarState.connectionId)
        let query = windowState.searchText
        let filtered: [TableInfo]
        if query.isEmpty {
            filtered = allTables
        } else {
            filtered = allTables.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
        guard !filtered.isEmpty else { return }

        let currentIndex: Int
        if let selected = sidebarState.selectedTables.first,
           let idx = filtered.firstIndex(of: selected) {
            currentIndex = idx
        } else {
            currentIndex = direction > 0 ? -1 : filtered.count
        }

        let nextIndex = currentIndex + direction
        guard nextIndex >= 0, nextIndex < filtered.count else { return }
        sidebarState.selectedTables = [filtered[nextIndex]]
    }

    private func writeSearchText(_ text: String) {
        guard let sidebarState, let windowState else { return }
        switch sidebarState.selectedSidebarTab {
        case .tables:
            windowState.searchText = text
        case .favorites:
            windowState.favoritesSearchText = text
        }
    }
}
