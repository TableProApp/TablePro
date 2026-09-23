//
//  RecentTabSwitcherController.swift
//  TablePro
//

import AppKit
import Combine
import os
import TableProEditorKit

/// What the switcher's rows read. Published so the list follows every step while it is on screen.
@MainActor
internal final class RecentTabSwitcherModel: ObservableObject {
    @Published internal private(set) var session: RecentTabSwitcherSession

    internal init(session: RecentTabSwitcherSession) {
        self.session = session
    }

    internal func update(_ session: RecentTabSwitcherSession) {
        self.session = session
    }
}

/// Where the switcher's list is drawn. The window's floating panel in the app, nothing in a test.
@MainActor
internal protocol RecentTabSwitcherPresenting: AnyObject {
    func presentRecentTabSwitcher(_ model: RecentTabSwitcherModel, over window: NSWindow?, onClose: @escaping () -> Void)
    func dismissRecentTabSwitcher()
}

/// Runs one Control-Tab: the first press arrives through the menu, and everything after it, the
/// repeats, Shift, Escape and the release that commits, arrives here while the chord is held.
///
/// The menu cannot carry the rest. A key equivalent fires on a press and never on a release, so
/// committing when the modifier comes up needs `flagsChanged`, which only an event monitor sees.
/// The monitor lives exactly as long as the switch, and the editor's own key chain asks
/// `claimKeyDown(_:)` first, so the order AppKit runs same-mask monitors in never decides which of
/// the two gets a key.
@MainActor
internal final class RecentTabSwitcherController {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "RecentTabSwitcher")

    /// Long enough that a tap to the previous tab shows nothing, the way Firefox (200 ms) and Zed
    /// (300 ms) hold theirs back.
    internal static let defaultPickerDelay: TimeInterval = 0.2

    private static weak var activeController: RecentTabSwitcherController?

    private weak var presenter: RecentTabSwitcherPresenting?
    private let pickerDelay: TimeInterval
    private let bindings: @MainActor () -> (forward: BoundKey?, backward: BoundKey?)
    private let announce: (String) -> Void

    private var model: RecentTabSwitcherModel?
    private var heldModifiers: NSEvent.ModifierFlags = []
    private var isOpen: ((RecentTabReference) -> Bool)?
    private var onCommit: ((RecentTabReference) -> Void)?
    private weak var hostWindow: NSWindow?
    private var eventMonitor: Any?
    private var observers: [any NSObjectProtocol] = []
    private var pickerWorkItem: DispatchWorkItem?

    internal init(
        presenter: RecentTabSwitcherPresenting?,
        pickerDelay: TimeInterval = defaultPickerDelay,
        bindings: @escaping @MainActor () -> (forward: BoundKey?, backward: BoundKey?) = userBindings,
        announce: @escaping (String) -> Void = AccessibilityAnnouncement.post
    ) {
        self.presenter = presenter
        self.pickerDelay = pickerDelay
        self.bindings = bindings
        self.announce = announce
    }

    internal var isActive: Bool { model != nil }

    internal var session: RecentTabSwitcherSession? { model?.session }

    internal static func userBindings() -> (forward: BoundKey?, backward: BoundKey?) {
        let keyboard = AppSettingsManager.shared.keyboard
        return (keyboard.shortcut(for: .switchToRecentTab), keyboard.shortcut(for: .switchToLeastRecentTab))
    }

    /// Puts the switch ahead of every editor's key chain, whichever of an editor's views holds focus,
    /// so a find field or Vim can never take the Escape that ends a switch.
    internal static func installEditorKeyClaim() {
        TextViewController.precedingKeyDownClaim = claimKeyDown
    }

    /// Hands a key to the switch in progress, for a key chain that runs ahead of the switcher's own
    /// monitor. True when the switch took it.
    internal static func claimKeyDown(_ event: NSEvent) -> Bool {
        guard let active = activeController, active.isActive, event.type == .keyDown else { return false }
        return active.handleKeyDown(keyCode: event.keyCode, modifiers: event.modifierFlags)
    }

    // MARK: - Session

    /// `trigger` is the event that ran the command. A switch the user is not holding a modifier for,
    /// because it came from a pointer in the menu or from a binding with no modifier, has no release
    /// to wait for, so it lands on the first candidate at once.
    ///
    /// The release is read from the event stream only, never from `NSEvent.modifierFlags`. The
    /// command runs inside the dispatch of the press that fired it, so the monitor is in place before
    /// AppKit takes the release off the queue, however fast the tap. The live flags describe the
    /// hardware instead, and measured, an event handed to the app rather than typed leaves them at
    /// zero, which would end every such switch on its first press.
    internal func begin(
        candidates: [RecentTabCandidate],
        leadsWithCurrentTab: Bool = true,
        direction: RecentTabSwitchDirection,
        trigger: NSEvent?,
        window: NSWindow?,
        isOpen: @escaping (RecentTabReference) -> Bool,
        onCommit: @escaping (RecentTabReference) -> Void
    ) {
        cancel()
        guard let session = RecentTabSwitcherSession(
            candidates: candidates,
            direction: direction,
            leadsWithCurrentTab: leadsWithCurrentTab
        ) else { return }

        let held = RecentTabSwitcherKeyCommand.heldModifiers(of: trigger)
        guard !held.isEmpty else {
            onCommit(session.highlighted.reference)
            return
        }

        model = RecentTabSwitcherModel(session: session)
        heldModifiers = held
        self.isOpen = isOpen
        self.onCommit = onCommit
        hostWindow = window
        Self.activeController = self

        installEventMonitor()
        observeEnd(of: window)
        schedulePicker()
        announce(session.highlighted.title)
        Self.logger.debug("begin candidates=\(candidates.count, privacy: .public)")
    }

    /// True for every key while a switch is held. A key the switch does not use is swallowed rather
    /// than passed on, because the modifier is still down and the editor would read it as a chord.
    ///
    /// A key that arrives without the held modifier means the release was never seen: AppKit runs
    /// no local monitor while a menu or a drag is tracking, and a modifier let go of then is lost.
    /// The switch ends and the key goes where it was meant to, rather than every key being
    /// swallowed until something else ends it.
    @discardableResult
    internal func handleKeyDown(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard isActive else { return false }
        guard !RecentTabSwitcherKeyCommand.releases(modifiers, held: heldModifiers) else {
            cancel()
            return false
        }
        let bound = bindings()
        let command = RecentTabSwitcherKeyCommand.resolve(
            keyCode: keyCode,
            modifiers: modifiers,
            forward: bound.forward,
            backward: bound.backward
        )
        switch command {
        case let .step(direction):
            step(direction)
        case .commit:
            commit()
        case .cancel:
            cancel()
        case .ignore:
            break
        }
        return true
    }

    internal func handleModifiersChanged(_ modifiers: NSEvent.ModifierFlags) {
        guard isActive, RecentTabSwitcherKeyCommand.releases(modifiers, held: heldModifiers) else { return }
        commit()
    }

    internal func cancel() {
        guard isActive else { return }
        Self.logger.debug("cancel")
        end()
    }

    private func step(_ direction: RecentTabSwitchDirection) {
        guard var session = model?.session, let isOpen else { return }
        guard session.step(direction, keeping: isOpen) else {
            cancel()
            return
        }
        model?.update(session)
        announce(session.highlighted.title)
    }

    /// A highlighted tab that closed while the chord was held is not replaced by its neighbour: the
    /// user never chose that one, so the switch ends where it started.
    private func commit() {
        guard let target = model?.session.highlighted.reference, let isOpen, let onCommit else { return }
        end()
        guard isOpen(target) else { return }
        onCommit(target)
    }

    /// Clears the state before the panel goes, because closing the panel calls back into
    /// `cancel()`, which must find nothing left to cancel.
    private func end() {
        model = nil
        isOpen = nil
        onCommit = nil
        heldModifiers = []
        hostWindow = nil
        pickerWorkItem?.cancel()
        pickerWorkItem = nil
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if Self.activeController === self {
            Self.activeController = nil
        }
        presenter?.dismissRecentTabSwitcher()
    }

    // MARK: - Wiring

    /// A press of any mouse button ends the switch and goes through untouched. With Control held a
    /// click is a secondary click, and the contextual menu it opens tracks events itself, so a
    /// release of Control inside it would never reach this monitor.
    private func installEventMonitor() {
        let mask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] nsEvent in
            nonisolated(unsafe) let event = nsEvent
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                switch event.type {
                case .flagsChanged:
                    self.handleModifiersChanged(event.modifierFlags)
                    return false
                case .keyDown:
                    return self.handleKeyDown(keyCode: event.keyCode, modifiers: event.modifierFlags)
                default:
                    self.cancel()
                    return false
                }
            }
            return consumed ? nil : nsEvent
        }
    }

    /// A switch belongs to the window and to the moment. Anything that takes the keyboard away,
    /// another window, another app, a menu opening, or the window closing, ends it without
    /// switching.
    private func observeEnd(of window: NSWindow?) {
        let center = NotificationCenter.default
        let endSwitch: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main,
            using: endSwitch
        ))
        observers.append(center.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main,
            using: endSwitch
        ))
        guard let window else { return }
        observers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main,
            using: endSwitch
        ))
        observers.append(center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main,
            using: endSwitch
        ))
    }

    private func schedulePicker() {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.showPicker() }
        }
        pickerWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + pickerDelay, execute: work)
    }

    private func showPicker() {
        guard let model else { return }
        presenter?.presentRecentTabSwitcher(model, over: hostWindow) { [weak self] in
            self?.cancel()
        }
    }
}
