//
//  PluginInstallProgressPresenter.swift
//  TablePro
//

import AppKit

/// The progress of a plugin download the user is waiting on, shown while it runs.
///
/// Every caller of `installMissingPlugin` used to discard the fraction it publishes, so pressing
/// Install closed the alert and left the app looking hung for the length of a network download.
/// The HIG asks for progress on anything past a couple of seconds, and a registry ZIP is reliably
/// past it.
///
/// A panel rather than an `NSAlert`, for two reasons. `AlertHelper` runs an alert application-modal
/// when no window qualifies, which is exactly the Finder-open case this exists for, and a modal run
/// loop cannot be updated from the `await` that is driving it. And an alert with no button is not
/// what `NSAlert` is for: this is a progress report, not a question.
@MainActor
internal final class PluginInstallProgressPresenter {
    private var panel: NSPanel?
    private var sheetParent: NSWindow?
    private let indicator = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")

    internal init() {}

    /// Presented as a sheet on the window the user was working in, and as a free-standing panel
    /// when there is none, which is how a Finder open before any window exists reaches the screen.
    internal func begin(title: String) {
        guard panel == nil else { return }
        label.stringValue = title
        let panel = makePanel()
        self.panel = panel

        guard let parent = AlertHelper.resolveWindow(nil) else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            return
        }
        sheetParent = parent
        parent.beginSheet(panel)
    }

    /// The first fraction that has actually moved is what turns the bar determinate. A zero is
    /// published before the first byte arrives, and a server that sends no `Content-Length`
    /// publishes nothing after it until the whole file is down, so adopting it would park a
    /// determinate bar at 0% for the entire download: the wait this panel exists to explain.
    /// Stopping the animation goes with the switch, or its timer runs on under a bar that is no
    /// longer using it.
    internal func update(fraction: Double) {
        let clamped = min(max(fraction, 0), 1)
        guard clamped > 0 else { return }
        if indicator.isIndeterminate {
            indicator.stopAnimation(nil)
            indicator.isIndeterminate = false
        }
        indicator.doubleValue = clamped * 100
    }

    internal func end() {
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

        /// Starts indeterminate because the first byte has not arrived yet, and a bar sitting at
        /// zero reads as stalled rather than as starting.
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
