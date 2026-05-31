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
    private var observationTask: Task<Void, Never>?

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
        searchField.setAccessibilityLabel(String(localized: "Filter"))
        view.addSubview(searchField)

        addChild(hostingController)
        let hostingView = hostingController.view
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

    func updateSidebarState(_ state: SharedSidebarState?, windowState: WindowSidebarState?) {
        observationTask?.cancel()
        self.sidebarState = state
        self.windowState = windowState
        guard let state, let windowState else {
            searchField.isHidden = true
            return
        }
        searchField.isHidden = false
        observationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.syncFromState(state, windowState: windowState)
                await Self.awaitChange(state: state, windowState: windowState)
            }
        }
    }

    private static func awaitChange(state: SharedSidebarState, windowState: WindowSidebarState) async {
        let box = ObservationContinuationBox()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                box.attach(continuation)
                withObservationTracking {
                    _ = state.selectedSidebarTab
                    _ = windowState.searchText
                    _ = windowState.favoritesSearchText
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

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.moveDown(_:)) else { return false }
        view.window?.makeFirstResponder(hostingController.view)
        return true
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
