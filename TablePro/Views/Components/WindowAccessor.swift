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

    func updateNSView(_ nsView: WindowAccessorView, context: Context) {
        nsView.onWindow = onWindow
    }
}

final class WindowAccessorView: NSView {
    var onWindow: ((NSWindow) -> Void)?
    private weak var capturedWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, window !== capturedWindow else { return }
        capturedWindow = window
        onWindow?(window)
    }
}
