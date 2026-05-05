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
            _ = state.searchText
            _ = state.selectedSidebarTab
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
            activeText = state.searchText
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

    private func writeSearchText(_ text: String) {
        guard let sidebarState else { return }
        switch sidebarState.selectedSidebarTab {
        case .tables:
            sidebarState.searchText = text
        case .favorites:
            windowState?.favoritesSearchText = text
        }
    }
}
