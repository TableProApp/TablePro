//
//  DoubleClickDetector.swift
//  TablePro
//
//  Transparent overlay that detects double-clicks on sidebar rows.
//  Used for preview tabs: single-click opens a preview tab, double-click opens a permanent tab.
//
//  Uses a single shared NSEvent monitor instead of one per row to avoid
//  O(n) monitors when tables are numerous.
//

import AppKit
import SwiftUI

struct DoubleClickDetector: NSViewRepresentable {
    var onDoubleClick: () -> Void

    func makeNSView(context: Context) -> SidebarDoubleClickView {
        let view = SidebarDoubleClickView()
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: SidebarDoubleClickView, context: Context) {
        nsView.onDoubleClick = onDoubleClick
    }
}

final class SidebarDoubleClickView: NSView {
    var onDoubleClick: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            SharedDoubleClickMonitor.shared.register(self)
        } else {
            SharedDoubleClickMonitor.shared.unregister(self)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override var acceptsFirstResponder: Bool { false }

    deinit {
        MainActor.assumeIsolated {
            SharedDoubleClickMonitor.shared.unregister(self)
        }
    }
}

/// Single shared event monitor that dispatches double-clicks to registered views.
/// Avoids O(n) monitors when many DoubleClickDetector overlays exist in the sidebar.
/// All callers run on the main thread (NSView lifecycle + NSEvent monitor).
@MainActor
private final class SharedDoubleClickMonitor {
    static let shared = SharedDoubleClickMonitor()

    private var registeredViews = NSHashTable<SidebarDoubleClickView>.weakObjects()
    private var monitor: Any?

    private init() {}

    func register(_ view: SidebarDoubleClickView) {
        registeredViews.add(view)
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                self?.handleMouseUp(event)
                return event
            }
        }
    }

    func unregister(_ view: SidebarDoubleClickView) {
        registeredViews.remove(view)
        if registeredViews.allObjects.isEmpty, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handleMouseUp(_ event: NSEvent) {
        guard event.clickCount == 2 else { return }

        for view in registeredViews.allObjects {
            guard let viewWindow = view.window,
                  event.window === viewWindow else { continue }
            let locationInView = view.convert(event.locationInWindow, from: nil)
            if view.bounds.contains(locationInView) {
                view.onDoubleClick?()
                break
            }
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
