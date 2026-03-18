//
//  FindPanelHostingView.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 3/10/25.
//

import SwiftUI
import AppKit
import Combine

/// A subclass of `NSHostingView` that hosts the SwiftUI `FindPanelView` in an 
/// AppKit context.
///
/// The `FindPanelHostingView` class is responsible for:
/// - Bridging between SwiftUI and AppKit by hosting the FindPanelView
/// - Managing keyboard event monitoring for the escape key
/// - Handling the dismissal of the find panel
/// - Providing proper view lifecycle management
/// - Ensuring proper cleanup of event monitors
///
/// This class is essential for integrating the SwiftUI-based find panel into the AppKit-based
/// text editor.
final class FindPanelHostingView: NSHostingView<FindPanelView> {
    private weak var viewModel: FindPanelViewModel?

    private var eventMonitor: Any?

    init(viewModel: FindPanelViewModel) {
        self.viewModel = viewModel
        super.init(rootView: FindPanelView(viewModel: viewModel))

        self.translatesAutoresizingMaskIntoConstraints = false

        self.wantsLayer = true
        self.layer?.backgroundColor = .clear

        self.translatesAutoresizingMaskIntoConstraints = false
    }

    @MainActor @preconcurrency required init(rootView: FindPanelView) {
        super.init(rootView: rootView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        removeEventMonitor()
    }

    // MARK: - Event Monitor Management

    func addEventMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event -> NSEvent? in
            if event.keyCode == 53 { // if esc pressed
                self.viewModel?.dismiss?()
                return nil // do not play "beep" sound
            }
            return event
        }
    }

    func removeEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}
