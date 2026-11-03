import AppKit
import Combine

// A panel, not an NSAlert: with no window an alert runs app-modal, and the await driving it cannot update it.
@MainActor
internal final class PluginInstallProgressPresenter: NSObject {
    internal typealias Install = @MainActor @Sendable (_ onBegin: @MainActor (_ pluginId: String) -> Void) async throws -> Void

    internal struct Display: Equatable {
        let message: String
        let fraction: Double?
        let canCancel: Bool

        static func make(pluginName: String, phase: PluginInstallTracker.Phase?) -> Display {
            switch phase {
            case .downloading(let fraction):
                return Display(message: downloadingMessage(pluginName), fraction: fraction, canCancel: true)
            case .installing, .completed:
                return Display(
                    message: String(format: String(localized: "Installing the %@ plugin…"), pluginName),
                    fraction: nil,
                    canCancel: false
                )
            case .failed, .none:
                return Display(message: downloadingMessage(pluginName), fraction: nil, canCancel: true)
            }
        }

        private static func downloadingMessage(_ pluginName: String) -> String {
            String(format: String(localized: "Downloading the %@ plugin…"), pluginName)
        }
    }

    private let pluginName: String
    private let tracker: PluginInstallTracker
    private var panel: NSPanel?
    private var sheetParent: NSWindow?
    private let indicator = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private lazy var cancelButton = NSButton(
        title: String(localized: "Cancel"),
        target: self,
        action: #selector(cancelInstall)
    )
    private var followed: AnyCancellable?
    private var pluginId: String?
    private var cancelTask: (() -> Void)?
    private(set) var didCancel = false

    private init(pluginName: String, tracker: PluginInstallTracker) {
        self.pluginName = pluginName
        self.tracker = tracker
        super.init()
    }

    // Ended before the caller presents a failure, since a second sheet on the window would queue.
    internal static func run(
        pluginName: String,
        window: NSWindow?,
        tracker: PluginInstallTracker = .shared,
        _ install: @escaping Install
    ) async throws {
        let presenter = PluginInstallProgressPresenter(pluginName: pluginName, tracker: tracker)
        let task = Task { @MainActor in
            try await install { pluginId in presenter.follow(pluginId: pluginId) }
        }
        presenter.cancelTask = { task.cancel() }
        presenter.begin(window: window)
        defer { presenter.end() }
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            guard !presenter.didCancel, !PluginInstallTracker.isCancellation(error) else { throw CancellationError() }
            throw error
        }
    }

    private func follow(pluginId: String) {
        self.pluginId = pluginId
        followed = tracker.$entries.sink { [weak self] entries in
            guard let self else { return }
            render(Display.make(pluginName: pluginName, phase: entries[pluginId]?.phase))
        }
    }

    @objc private func cancelInstall() {
        didCancel = true
        cancelButton.isEnabled = false
        if let pluginId {
            tracker.cancel(pluginId: pluginId)
        }
        cancelTask?()
    }

    private func begin(window: NSWindow?) {
        guard panel == nil else { return }
        let panel = makePanel()
        self.panel = panel
        render(Display.make(pluginName: pluginName, phase: nil))

        guard let parent = AlertHelper.resolveWindow(window) else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            return
        }
        sheetParent = parent
        parent.beginSheet(panel)
    }

    private func render(_ display: Display) {
        label.stringValue = display.message
        indicator.setAccessibilityLabel(display.message)
        panel?.setAccessibilityLabel(display.message)
        cancelButton.isEnabled = display.canCancel && !didCancel
        if let fraction = display.fraction {
            if indicator.isIndeterminate {
                indicator.stopAnimation(nil)
                indicator.isIndeterminate = false
            }
            indicator.doubleValue = min(max(fraction, 0), 1) * 100
        } else if !indicator.isIndeterminate {
            indicator.isIndeterminate = true
            indicator.startAnimation(nil)
        }
    }

    private func end() {
        followed = nil
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
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .body)
        label.lineBreakMode = .byTruncatingMiddle

        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.style = .bar
        indicator.isIndeterminate = true
        indicator.minValue = 0
        indicator.maxValue = 100
        indicator.startAnimation(nil)

        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.bezelStyle = .push
        cancelButton.keyEquivalent = "\u{1b}"

        content.addSubview(label)
        content.addSubview(indicator)
        content.addSubview(cancelButton)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 360),

            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),

            indicator.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            indicator.trailingAnchor.constraint(equalTo: label.trailingAnchor),
            indicator.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 12),

            cancelButton.trailingAnchor.constraint(equalTo: label.trailingAnchor),
            cancelButton.topAnchor.constraint(equalTo: indicator.bottomAnchor, constant: 16),
            cancelButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: content.fittingSize),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        panel.contentView = content
        panel.title = String(localized: "Installing Plugin")
        panel.isReleasedWhenClosed = false
        return panel
    }
}
