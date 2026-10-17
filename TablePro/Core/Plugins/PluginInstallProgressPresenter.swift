import AppKit

// A panel, not an NSAlert: with no window an alert runs app-modal, and the await driving it cannot update it.
@MainActor
internal final class PluginInstallProgressPresenter {
    private var panel: NSPanel?
    private var sheetParent: NSWindow?
    private let indicator = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")

    private init() {}

    // Ended before the caller presents a failure, since a second sheet on the window would queue.
    internal static func run(
        title: String,
        window: NSWindow?,
        _ install: (_ progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> Void
    ) async throws {
        let presenter = PluginInstallProgressPresenter()
        presenter.begin(title: title, window: window)
        defer { presenter.end() }
        try await install { fraction in presenter.update(fraction: fraction) }
    }

    private func begin(title: String, window: NSWindow?) {
        guard panel == nil else { return }
        label.stringValue = title
        let panel = makePanel()
        self.panel = panel

        guard let parent = AlertHelper.resolveWindow(window) else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            return
        }
        sheetParent = parent
        parent.beginSheet(panel)
    }

    // 0 stays indeterminate; a download without a Content-Length reports nothing before the final 1.
    private func update(fraction: Double) {
        let clamped = min(max(fraction, 0), 1)
        guard clamped > 0 else { return }
        if indicator.isIndeterminate {
            indicator.stopAnimation(nil)
            indicator.isIndeterminate = false
        }
        indicator.doubleValue = clamped * 100
    }

    private func end() {
        indicator.stopAnimation(nil)
        guard let panel else { return }
        self.panel = nil
        if let sheetParent {
            self.sheetParent = nil
            sheetParent.endSheet(panel)
            return
        }
        panel.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 92))

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .body)
        label.lineBreakMode = .byTruncatingMiddle

        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.style = .bar
        indicator.isIndeterminate = true
        indicator.minValue = 0
        indicator.maxValue = 100
        indicator.startAnimation(nil)

        content.addSubview(label)
        content.addSubview(indicator)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),

            indicator.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            indicator.trailingAnchor.constraint(equalTo: label.trailingAnchor),
            indicator.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 12),
            indicator.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])

        let panel = NSPanel(
            contentRect: content.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        panel.contentView = content
        panel.title = String(localized: "Installing Plugin")
        panel.isReleasedWhenClosed = false
        panel.setAccessibilityLabel(label.stringValue)
        return panel
    }
}
