import AppKit
import SwiftUI

struct DoubleClickDetector: NSViewRepresentable {
    var onDoubleClick: () -> Void

    func makeNSView(context: Context) -> DoubleClickPassThroughView {
        let view = DoubleClickPassThroughView()
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: DoubleClickPassThroughView, context: Context) {
        nsView.onDoubleClick = onDoubleClick
    }
}

final class DoubleClickPassThroughView: NSView {
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

@MainActor
private final class SharedDoubleClickMonitor {
    static let shared = SharedDoubleClickMonitor()

    private var registeredViews = NSHashTable<DoubleClickPassThroughView>.weakObjects()
    private var monitor: Any?

    private init() {}

    func register(_ view: DoubleClickPassThroughView) {
        registeredViews.add(view)
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.handleMouseDown(event)
                return event
            }
        }
    }

    func unregister(_ view: DoubleClickPassThroughView) {
        registeredViews.remove(view)
        if registeredViews.allObjects.isEmpty, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handleMouseDown(_ event: NSEvent) {
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
