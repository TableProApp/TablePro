//
//  FoldPreviewController.swift
//  TablePro
//

import AppKit
import CodeEditLanguages
import CodeEditSourceEditor
import SwiftUI

/// Shows the block behind a collapsed fold when the pointer rests on its placeholder.
///
/// The placeholder is drawn by the layout manager rather than being a view of its own, so there is nothing to attach a
/// tracking area to. Hovering is resolved by hit testing the pointer against the collapsed folds instead.
@MainActor
final class FoldPreviewController: NSObject {
    /// How long the pointer must rest before a peek opens.
    private static let hoverDelay: Duration = .milliseconds(400)

    /// The most text a peek reads out of a block. A fold can hide a whole script; a peek is a look, not a copy.
    private static let previewCharacterLimit = 20_000

    private weak var controller: TextViewController?
    private var monitor: Any?
    private var overlay: FoldHoverOverlayView?
    private var popover: NSPopover?
    private var shownRange: Range<Int>?
    private var pendingTask: Task<Void, Never>?

    var language: CodeLanguage = .sql

    func install(controller: TextViewController) {
        self.controller = controller

        // The placeholder is drawn by the layout manager and has no view to track. A transparent overlay carries the
        // tracking area instead, and passes every click straight through to the editor beneath it.
        if let textView = controller.textView {
            let overlay = FoldHoverOverlayView(frame: textView.bounds)
            overlay.autoresizingMask = [.width, .height]
            overlay.onMouseMoved = { [weak self] event in self?.hover(at: event) }
            overlay.onMouseExited = { [weak self] in self?.dismiss() }
            textView.addSubview(overlay)
            self.overlay = overlay
        }

        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .leftMouseDown, .keyDown]
        ) { [weak self] event in
            self?.dismiss()
            return event
        }
    }

    func destroy() {
        pendingTask?.cancel()
        pendingTask = nil
        overlay?.removeFromSuperview()
        overlay = nil
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        dismiss()
        controller = nil
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Hover

    private func hover(at event: NSEvent) {
        guard let textView = controller?.textView else {
            dismiss()
            return
        }

        let point = textView.convert(event.locationInWindow, from: nil)
        guard let hit = controller?.collapsedFold(at: point) else {
            dismiss()
            return
        }
        guard hit.hiddenRange != shownRange else { return }

        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            try? await Task.sleep(for: Self.hoverDelay)
            guard !Task.isCancelled else { return }
            self?.present(hit)
        }
    }

    private func present(_ hit: CollapsedFoldHit) {
        guard let controller, let textView = controller.textView, textView.window != nil else { return }
        guard let block = controller.documentText(in: hit.blockRange, limit: Self.previewCharacterLimit) else { return }

        let layout = FoldPreviewMetrics.layout(for: block, font: ThemeEngine.shared.editorFonts.font)
        guard !layout.text.isEmpty else { return }

        dismiss()

        let content = NSHostingController(rootView: FoldPreviewView(layout: layout, language: language))
        content.sizingOptions = [.preferredContentSize]

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = content

        // `rectForOffset` reports in the text view's own coordinate space, and the text view is flipped, so `.maxY`
        // is the edge below the placeholder. Anchoring to the text view directly lets AppKit resolve the screen
        // position through the scroll view, which a stand-in view positioned by hand cannot do correctly.
        popover.show(relativeTo: hit.rect, of: textView, preferredEdge: .maxY)

        self.popover = popover
        shownRange = hit.hiddenRange
    }

    private func dismiss() {
        pendingTask?.cancel()
        pendingTask = nil
        popover?.performClose(nil)
        popover = nil
        shownRange = nil
    }
}

// MARK: - NSPopoverDelegate

extension FoldPreviewController: NSPopoverDelegate {
    /// A transient popover closes itself on the next event outside it, without routing through ``dismiss()``. Clearing
    /// the shown range here is what lets the same placeholder open a second time.
    func popoverDidClose(_ notification: Notification) {
        popover = nil
        shownRange = nil
    }
}
