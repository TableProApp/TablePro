//
//  LineFoldPlaceholderTracker.swift
//  CodeEditSourceEditor
//

import AppKit
import CodeEditTextView

/// Reports which collapsed fold's placeholder the pointer is resting on.
///
/// A placeholder is drawn by the layout manager rather than being a view, so there is nothing to hang a tracking area
/// on. The tracking area goes on the text view itself with this object as its owner, which is what an owner is for:
/// `NSTrackingArea` takes any object, so reporting pointer movement needs no view of its own and no hit testing to
/// step around. `.inVisibleRect` leaves AppKit to keep the area matched to what is on screen, so nothing has to
/// recompute it when the document grows or the editor is resized.
///
/// Scrolling moves placeholders under a pointer that never moved, and a stationary pointer generates no events, so the
/// editor's own scroll notification re-resolves from the window's current pointer location.
@MainActor
final class LineFoldPlaceholderTracker: NSResponder {
    private weak var model: LineFoldModel?
    private weak var trackedView: TextView?
    private var trackingArea: NSTrackingArea?
    private var scrollObserver: NSObjectProtocol?

    init(model: LineFoldModel) {
        self.model = model
        super.init()
        install()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
    }

    private func install() {
        guard let controller = model?.controller, let textView = controller.textView else { return }

        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        textView.addTrackingArea(area)
        trackingArea = area
        trackedView = textView

        scrollObserver = NotificationCenter.default.addObserver(
            forName: TextViewController.scrollPositionDidUpdateNotification,
            object: controller,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resolveFromCurrentPointer()
            }
        }
    }

    /// Removes the tracking area. The area's owner is this object, so it must not outlive it.
    func destroy() {
        if let trackingArea {
            trackedView?.removeTrackingArea(trackingArea)
        }
        trackingArea = nil
        trackedView = nil
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
        scrollObserver = nil
        model?.setPlaceholderHover(nil)
    }

    override func mouseEntered(with event: NSEvent) {
        resolve(atWindowPoint: event.locationInWindow)
    }

    override func mouseMoved(with event: NSEvent) {
        resolve(atWindowPoint: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        model?.setPlaceholderHover(nil)
    }

    private func resolveFromCurrentPointer() {
        guard let window = trackedView?.window else { return }
        resolve(atWindowPoint: window.mouseLocationOutsideOfEventStream)
    }

    private func resolve(atWindowPoint windowPoint: CGPoint) {
        guard let controller = model?.controller, let textView = controller.textView else { return }

        // Nothing is folded in most documents most of the time, and resolving a point to an offset is a layout
        // query. Asking whether there is anything to hit first keeps moving the pointer over an ordinary document
        // free.
        guard !textView.layoutManager.attachments.isEmpty else {
            model?.setPlaceholderHover(nil)
            return
        }

        let point = textView.convert(windowPoint, from: nil)
        guard textView.visibleRect.contains(point) else {
            model?.setPlaceholderHover(nil)
            return
        }
        model?.setPlaceholderHover(controller.placeholderHover(at: point))
    }
}
