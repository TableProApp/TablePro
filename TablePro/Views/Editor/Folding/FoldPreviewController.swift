//
//  FoldPreviewController.swift
//  TablePro
//

import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import SwiftUI

/// Shows the block behind a collapsed fold while the pointer rests on its placeholder.
///
/// Where the pointer is comes from the editor, which is the only thing that can answer it: a placeholder is drawn by
/// the layout manager rather than being a view, so there is nothing outside the editor to track. This decides how
/// long to wait and what to show.
@MainActor
final class FoldPreviewController: NSObject {
    /// How long the pointer must rest before a peek opens.
    private static let hoverDelay: Duration = .milliseconds(400)

    /// The most text a peek reads out of a block. A fold can hide a whole script; a peek is a look, not a copy.
    private static let previewCharacterLimit = 20_000

    private weak var controller: TextViewController?
    private var popover: NSPopover?
    private var pendingTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    /// The fold the peek is showing or waiting to show. Hovering the same placeholder reports the same hit many
    /// times over, and restarting the wait on each of them would mean the peek never opens.
    private var activeHit: CollapsedFoldHit?

    var language: CodeLanguage = .sql

    func install(controller: TextViewController) {
        self.controller = controller

        // A peek is a look at code, so it goes away when that code changes underneath it or when the user leaves the
        // app. Watching for a window losing key would be wrong here: showing the peek can take key away from the
        // editor's own window, and the peek would close itself the moment it opened.
        observers = [
            NotificationCenter.default.addObserver(
                forName: TextViewController.foldStateDidChangeNotification,
                object: controller,
                queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.dismiss() } },
            NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.dismiss() } }
        ]
    }

    func destroy() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        dismiss()
        controller = nil
    }

    // MARK: - Hover

    /// Reports where the pointer is, from ``CodeEditSourceEditor/TextViewCoordinator``.
    func hoverDidChange(to hit: CollapsedFoldHit?) {
        guard hit != activeHit else { return }

        // Closing the popover runs the delegate, which drops the active hit, so the new one is recorded after.
        dismiss()
        activeHit = hit
        guard let hit else { return }

        pendingTask = Task { [weak self] in
            try? await Task.sleep(for: Self.hoverDelay)
            guard !Task.isCancelled else { return }
            self?.present(hit)
        }
    }

    /// Closes the peek and forgets what it was for, so the same placeholder can open it again.
    func dismiss() {
        pendingTask?.cancel()
        pendingTask = nil
        popover?.performClose(nil)
        popover = nil
    }

    // MARK: - Presentation

    private func present(_ hit: CollapsedFoldHit) {
        guard let controller, let textView = controller.textView, textView.window != nil else { return }
        guard let block = controller.documentText(in: hit.blockRange, limit: Self.previewCharacterLimit) else { return }

        let layout = FoldPreviewMetrics.layout(for: block, font: ThemeEngine.shared.editorFonts.font)
        guard !layout.text.isEmpty else { return }

        let content = NSHostingController(rootView: FoldPreviewView(layout: layout, language: language))
        content.sizingOptions = [.preferredContentSize]

        let popover = NSPopover()
        // A transient popover installs its own event monitor and swallows the click that dismisses it, so the click
        // that should have expanded the fold did nothing and the reader had to click the chip twice. This peek is a
        // look at code and nothing in it is clickable, so it is closed by the things that make it stale instead: the
        // pointer leaving the chip, the fold changing, the text changing, or the window going away.
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = content

        // `rectForOffset` reports in the text view's own coordinate space, and the text view is flipped, so `.maxY`
        // is the edge below the placeholder. Anchoring to the text view directly lets AppKit resolve the screen
        // position through the scroll view, which a stand-in view positioned by hand cannot do correctly.
        popover.show(relativeTo: hit.rect, of: textView, preferredEdge: .maxY)

        self.popover = popover
    }
}

// MARK: - NSPopoverDelegate

extension FoldPreviewController: NSPopoverDelegate {
    /// AppKit closes a popover on its own when the view it is anchored to leaves the window. Dropping the hit here is
    /// what lets the same placeholder open a peek again afterwards.
    func popoverDidClose(_ notification: Notification) {
        popover = nil
        activeHit = nil
    }
}
