//
//  SidebarContainerViewController.swift
//  TablePro
//
//  AppKit container that places a native NSSearchField above the SwiftUI sidebar content.
//  The search field inherits sidebar vibrancy from the NSSplitViewItem automatically.
//

import AppKit
import SwiftUI

@MainActor
internal final class SidebarContainerViewController: NSViewController {
    private let searchField = NSSearchField()
    private var hostingController: NSHostingController<AnyView>
    private var sidebarState: SharedSidebarState?
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
        searchField.controlSize = .large
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

    // MARK: - State Management

    func updateSidebarState(_ state: SharedSidebarState?) {
        observationGeneration += 1
        sidebarState = state
        guard let state else {
            searchField.isHidden = true
            return
        }
        searchField.isHidden = false
        syncFromState(state)
        startObserving(state, generation: observationGeneration)
    }

    private func startObserving(_ state: SharedSidebarState, generation: Int) {
        withObservationTracking {
            _ = state.searchText
            _ = state.selectedSidebarTab
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generation == self.observationGeneration,
                      let sidebarState = self.sidebarState else { return }
                self.syncFromState(sidebarState)
                self.startObserving(sidebarState, generation: generation)
            }
        }
    }

    private func syncFromState(_ state: SharedSidebarState) {
        if searchField.stringValue != state.searchText {
            searchField.stringValue = state.searchText
        }
        searchField.placeholderString = state.selectedSidebarTab == .tables
            ? String(localized: "Filter")
            : String(localized: "Filter favorites")
    }
}

// MARK: - NSSearchFieldDelegate

extension SidebarContainerViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField else { return }
        sidebarState?.searchText = field.stringValue
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        sidebarState?.searchText = ""
    }
}
