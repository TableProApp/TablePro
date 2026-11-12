import AppKit
import SwiftUI

// Reports whether any part of the hosting window is on screen. A minimized, hidden or fully covered window,
// a background window tab, and a view taken out of its window all report false; `onDisappear` misses most of these.
struct WindowVisibilityReader: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> WindowVisibilityView {
        let view = WindowVisibilityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: WindowVisibilityView, context: Context) {
        nsView.onChange = onChange
    }

    static func dismantleNSView(_ nsView: WindowVisibilityView, coordinator: ()) {
        nsView.stopObserving()
    }
}

final class WindowVisibilityView: NSView {
    var onChange: ((Bool) -> Void)?
    private var observer: NSObjectProtocol?
    private var reported: Bool?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        if let window {
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
        }
        // Moving into a window happens inside a SwiftUI update, which must not publish.
        DispatchQueue.main.async { [weak self] in self?.report() }
    }

    func stopObserving() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
    }

    private func report() {
        let isVisible = window?.occlusionState.contains(.visible) ?? false
        guard isVisible != reported else { return }
        reported = isVisible
        onChange?(isVisible)
    }
}
