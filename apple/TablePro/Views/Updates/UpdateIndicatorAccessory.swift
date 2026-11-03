import AppKit
import Combine
import SwiftUI

// Added only while an update is pending: a hidden titlebar accessory still takes its width from the toolbar.
@MainActor
final class UpdateIndicatorAccessory {
    let controller: UpdateIndicatorAccessoryController
    private weak var window: NSWindow?
    private var cancellable: AnyCancellable?

    init(window: NSWindow, center: UpdateCenter = .shared) {
        self.window = window
        controller = UpdateIndicatorAccessoryController(center: center)
        cancellable = center.$status
            .removeDuplicates()
            .sink { [weak self] status in self?.apply(status) }
    }

    var isInstalled: Bool {
        window?.titlebarAccessoryViewControllers.contains { $0 === controller } ?? false
    }

    private func apply(_ status: UpdateStatus) {
        guard let window else { return }
        controller.show(status)
        let index = window.titlebarAccessoryViewControllers.firstIndex { $0 === controller }
        switch (status.indicator, index) {
        case (.hidden, let index?):
            window.removeTitlebarAccessoryViewController(at: index)
        case (.updateAvailable, nil), (.relaunchToUpdate, nil):
            window.addTitlebarAccessoryViewController(controller)
        default:
            break
        }
    }
}

@MainActor
final class UpdateIndicatorAccessoryController: NSTitlebarAccessoryViewController, NSPopoverDelegate {
    private static let trailingInset: CGFloat = 16

    let button = NSButton(title: "", target: nil, action: nil)
    private let center: UpdateCenter
    private var status = UpdateStatus()
    private var popover: NSPopover?

    init(center: UpdateCenter) {
        self.center = center
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .trailing
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("UpdateIndicatorAccessoryController does not support NSCoder init")
    }

    // AppKit gives a trailing accessory the toolbar row's height, so the button centers itself in it.
    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 28))
        button.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 26.0, *) {
            button.bezelStyle = .glass
            button.borderShape = .capsule
            button.controlSize = .large
        } else {
            button.bezelStyle = .toolbar
        }
        button.target = self
        button.action = #selector(buttonClicked(_:))
        button.setAccessibilityIdentifier("update-indicator-button")
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        view = container
        applyStatus()
    }

    // An open popover does not re-render with its presenter, so a change closes it rather than leave it stale.
    func show(_ status: UpdateStatus) {
        guard status != self.status else { return }
        self.status = status
        popover?.close()
        guard isViewLoaded else { return }
        applyStatus()
    }

    private func applyStatus() {
        button.title = status.indicatorTitle ?? ""
        button.toolTip = status.indicatorHelp
        let width = ceil(button.fittingSize.width) + Self.trailingInset
        view.setFrameSize(NSSize(width: width, height: view.frame.height))
    }

    @objc private func buttonClicked(_ sender: NSButton) {
        switch status.indicator {
        case .hidden:
            break
        case .updateAvailable:
            center.performPrimaryAction()
        case .relaunchToUpdate:
            togglePopover(relativeTo: sender)
        }
    }

    private func togglePopover(relativeTo button: NSButton) {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        let status = status
        let popover = PopoverPresenter.show(relativeTo: button.bounds, of: button, behavior: .transient) { dismiss in
            UpdateReadyPopoverView(
                status: status,
                onLater: dismiss,
                onRelaunch: { [weak self] in
                    dismiss()
                    self?.center.relaunch()
                }
            )
        }
        popover.delegate = self
        self.popover = popover
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
    }
}
