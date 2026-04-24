//
//  FeedbackWindowController.swift
//  TablePro
//

import AppKit
import SwiftUI

@MainActor
final class FeedbackWindowController {
    static let shared = FeedbackWindowController()
    private var panel: NSPanel?
    private var closeObserver: NSObjectProtocol?
    private let viewModel = FeedbackViewModel()

    private init() {}

    func showFeedbackPanel() {
        if let existingPanel = panel {
            existingPanel.makeKeyAndOrderFront(nil)
            return
        }

        viewModel.captureTargetWindow = NSApp.keyWindow ?? NSApp.mainWindow

        let rootView = FeedbackView(viewModel: viewModel)
            .fixedSize(horizontal: false, vertical: true)

        let hostingView = NSHostingView(rootView: rootView)
        let size = hostingView.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier("feedback")
        panel.title = String(localized: "Report an Issue")
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenNone]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = hostingView
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.panel = nil
                self?.viewModel.captureTargetWindow = nil
                self?.viewModel.clearSubmissionResult()
                if let observer = self?.closeObserver {
                    NotificationCenter.default.removeObserver(observer)
                }
                self?.closeObserver = nil
            }
        }
    }
}
