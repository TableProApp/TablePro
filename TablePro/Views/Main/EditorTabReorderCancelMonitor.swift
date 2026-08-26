//
//  EditorTabReorderCancelMonitor.swift
//  TablePro
//

import AppKit
import SwiftUI

/// Owns the Escape key while a tab reorder is in flight, and nothing else.
///
/// It exists because the monitor needs a lifetime and `EditorTabStrip` is a value with no `deinit`.
/// Every local monitor in this app is owned by a reference type that installs and removes it
/// (`InlineSuggestionManager`, `CellOverlayBase`, `QuickSwitcherPanelView`); a `View` cannot be,
/// so the representable's coordinator is.
///
/// It draws nothing, takes no clicks and publishes nothing to accessibility. That is not
/// decoration: a view mounted over the track covers every tab in the accessibility tree however
/// little it draws and however it hit-tests, measured, so XCUITest found no tab hittable at all.
/// It is mounted as a background for the same reason.
internal struct EditorTabReorderCancelMonitor: NSViewRepresentable {
    internal let isReordering: Bool
    internal let onCancel: () -> Void

    internal func makeNSView(context: Context) -> NSView {
        InertView()
    }

    internal func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onCancel = onCancel
        context.coordinator.setCancelMonitorActive(isReordering)
    }

    internal func makeCoordinator() -> Coordinator {
        Coordinator(onCancel: onCancel)
    }

    /// SwiftUI tears the representable down here and nowhere else, so this is where a monitor that
    /// outlives its drag would otherwise leak.
    internal static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.setCancelMonitorActive(false)
    }

    @MainActor
    internal final class Coordinator {
        internal var onCancel: () -> Void
        private var cancelMonitor: Any?

        internal init(onCancel: @escaping () -> Void) {
            self.onCancel = onCancel
        }

        /// No `deinit`: `NSEvent.removeMonitor` is main-actor work and a `deinit` is not isolated,
        /// so the release would have to hop and might never run. The monitor is bounded from the
        /// other end instead. It exists only while a reorder is in flight, and every exit from that
        /// state, a commit, an Escape, a tab closing, the pane going away, comes back through
        /// `updateNSView` with `isReordering` false. `dismantleNSView` is the backstop for the view
        /// itself being destroyed mid-drag.
        internal func setCancelMonitorActive(_ isActive: Bool) {
            guard isActive != (cancelMonitor != nil) else { return }
            if isActive {
                install()
            } else {
                remove()
            }
        }

        /// Escape is swallowed while a reorder is in flight, so the key that abandons the drag does
        /// not also close a sheet or clear a search field behind it.
        private func install() {
            cancelMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] nsEvent in
                nonisolated(unsafe) let event = nsEvent
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, event.keyCode == KeyCode.escape.rawValue else { return false }
                    self.onCancel()
                    return true
                }
                return handled ? nil : nsEvent
            }
        }

        private func remove() {
            guard let cancelMonitor else { return }
            NSEvent.removeMonitor(cancelMonitor)
            self.cancelMonitor = nil
        }
    }
}

/// Present so the coordinator has a lifetime, and invisible to everything else.
internal final class InertView: NSView {
    override internal func hitTest(_ point: NSPoint) -> NSView? { nil }

    override internal func isAccessibilityElement() -> Bool { false }

    override internal func accessibilityChildren() -> [Any]? { nil }
}
