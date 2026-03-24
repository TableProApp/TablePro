import SwiftUI

/// Captures the hosting NSWindow from within a SwiftUI view hierarchy.
/// Use as a `.background { WindowAccessor { window in ... } }` modifier.
/// Uses `viewDidMoveToWindow` for synchronous capture — no async deferral,
/// so the window is available before any notifications fire.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowAccessorView {
        let view = WindowAccessorView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: WindowAccessorView, context: Context) {}
}

final class WindowAccessorView: NSView {
    var onWindow: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            onWindow?(window)
        }
    }
}
