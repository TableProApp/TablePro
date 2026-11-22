import AppKit
import Combine
import os

enum ShortcutRecordingStep: Equatable {
    case pass
    case cancelAndPass
    case holdModifiers(NSEvent.ModifierFlags)
    case swallow
    case cancel
    case remove
    case refuse(String)
    case capture(BoundKey)
}

struct ShortcutRecordingFeedback: Equatable {
    let action: ShortcutAction
    let message: String
}

struct ShortcutReassignment: Equatable {
    let action: ShortcutAction
    let key: BoundKey
    let holders: [ShortcutAction]

    var title: String {
        String(format: String(localized: "Reassign %@ to “%@”?"), key.displayString, action.displayName)
    }

    var message: String {
        if holders.count == 1, let holder = holders.first {
            return String(
                format: String(localized: "It is used by “%@” in %@, which will have no shortcut."),
                holder.displayName,
                holder.category.displayName
            )
        }
        let names = holders.map { String(format: String(localized: "“%@”"), $0.displayName) }
        return String(
            format: String(localized: "It is used by %@. They will have no shortcut."),
            ListFormatter.localizedString(byJoining: names)
        )
    }
}

@MainActor
final class ShortcutRecordingSession: ObservableObject {
    private struct Tokens {
        var monitor: Any?
        var resignObserver: (any NSObjectProtocol)?
    }

    @Published private(set) var recording: ShortcutAction?
    @Published private(set) var heldModifiers: NSEvent.ModifierFlags = []
    @Published private(set) var feedback: ShortcutRecordingFeedback?
    @Published private(set) var reassignment: ShortcutReassignment?

    private let keyboard: SettingsSlice<KeyboardSettings>
    private let signalRefusal: @MainActor (String) -> Void
    private weak var window: NSWindow?
    private weak var anchor: NSView?
    // A lock, so the nonisolated deinit can still remove the monitor.
    private let tokens = OSAllocatedUnfairLock<Tokens>(uncheckedState: Tokens())

    init(
        keyboard: SettingsSlice<KeyboardSettings>,
        signalRefusal: @escaping @MainActor (String) -> Void = { ShortcutRecordingSession.beepAndAnnounce($0) }
    ) {
        self.keyboard = keyboard
        self.signalRefusal = signalRefusal
    }

    deinit {
        let current = tokens.withLockUnchecked { $0 }
        if let monitor = current.monitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = current.resignObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // A local monitor, because AppKit hands a menu key equivalent such as Cmd-W to the menu before any keyDown.
    func begin(_ action: ShortcutAction, anchor: NSView? = nil) {
        cancel()
        SystemHotkeyChecker.shared.reload()
        let window = anchor?.window ?? NSApp.keyWindow
        self.window = window
        self.anchor = anchor ?? window?.firstResponder as? NSView
        if feedback?.action != action {
            feedback = nil
        }
        recording = action
        install(observing: window)
    }

    func toggle(_ action: ShortcutAction, anchor: NSView? = nil) {
        if recording == action {
            cancel()
        } else {
            begin(action, anchor: anchor)
        }
    }

    // Never moves focus: the control that started recording keeps it.
    func cancel() {
        let current = tokens.withLockUnchecked { tokens -> Tokens in
            let old = tokens
            tokens = Tokens()
            return old
        }
        if let monitor = current.monitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = current.resignObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        window = nil
        anchor = nil
        if recording != nil {
            recording = nil
        }
        if !heldModifiers.isEmpty {
            heldModifiers = []
        }
    }

    func reset() {
        cancel()
        feedback = nil
    }

    func confirm(_ request: ShortcutReassignment) {
        reassignment = nil
        keyboard.value = keyboard.value.reassigning(
            request.key,
            to: request.action,
            enabledModules: AppModule.storedEnabledModules()
        )
    }

    func dismissReassignment() {
        reassignment = nil
    }

    @discardableResult
    func perform(_ step: ShortcutRecordingStep, for action: ShortcutAction) -> Bool {
        switch step {
        case .pass:
            return false
        case .cancelAndPass:
            cancel()
            return false
        case .holdModifiers(let flags):
            if heldModifiers != flags {
                heldModifiers = flags
            }
            return true
        case .swallow:
            return true
        case .cancel:
            cancel()
            return true
        case .remove:
            finish(action)
            keyboard.value = keyboard.value.clearing(action)
            return true
        case .refuse(let message):
            refuse(message, for: action)
            return true
        case .capture(let key):
            capture(key, for: action)
            return true
        }
    }

    nonisolated static func classify(
        _ event: NSEvent,
        recording action: ShortcutAction,
        isInRecordingWindow: Bool,
        hitsRecordingButton: Bool
    ) -> ShortcutRecordingStep {
        guard isInRecordingWindow else { return .pass }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // The button's own action toggles recording off.
            return hitsRecordingButton ? .pass : .cancelAndPass
        case .flagsChanged:
            return .holdModifiers(event.modifierFlags.intersection(chordModifiers))
        case .keyDown:
            break
        default:
            return .pass
        }
        if event.isARepeat {
            return .swallow
        }
        let modifiers = event.modifierFlags.intersection(chordModifiers)
        switch event.keyCode {
        case KeyCode.tab.rawValue where modifiers.isDisjoint(with: [.command, .control, .option]):
            return .cancelAndPass
        case KeyCode.escape.rawValue where modifiers.isEmpty:
            return .cancel
        case KeyCode.delete.rawValue where modifiers.isEmpty:
            return .remove
        default:
            let key = BoundKey(capturing: event)
            return action.accepts(key) ? .capture(key) : .refuse(action.modifierRefusal)
        }
    }

    nonisolated private static let chordModifiers: NSEvent.ModifierFlags = [.command, .option, .shift, .control]

    static func beepAndAnnounce(_ message: String) {
        NSSound.beep()
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    private func install(observing window: NSWindow?) {
        let monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] nsEvent in
            nonisolated(unsafe) let event = nsEvent
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : nsEvent
        }
        let observer = window.map { window in
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            }
        }
        tokens.withLockUnchecked { $0 = Tokens(monitor: monitor, resignObserver: observer) }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let action = recording else { return false }
        // The pane's host is hidden, not removed, when another pane shows.
        if let anchor, anchor.window == nil || anchor.isHiddenOrHasHiddenAncestor {
            cancel()
            return false
        }
        let isInWindow = window.map { event.window === $0 && $0.isKeyWindow } ?? false
        let isMouseDown = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type)
        let step = Self.classify(
            event,
            recording: action,
            isInRecordingWindow: isInWindow,
            hitsRecordingButton: isMouseDown && Self.recorderAction(at: event) == action
        )
        return perform(step, for: action)
    }

    private static func recorderAction(at event: NSEvent) -> ShortcutAction? {
        guard let contentView = event.window?.contentView else { return nil }
        let point = contentView.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        var view = contentView.hitTest(point)
        while let current = view {
            if let button = current as? ShortcutRecorderButton {
                return button.shortcutAction
            }
            view = current.superview
        }
        return nil
    }

    private func capture(_ key: BoundKey, for action: ShortcutAction) {
        let settings = keyboard.value
        switch ShortcutConflictResolver.resolve(key, for: action, in: settings) {
        case .systemReserved:
            refuse(String(format: String(localized: "%@ is used by macOS."), key.displayString), for: action)
        case .reserved(let name):
            refuse(String(format: String(localized: "%@ is used by “%@”."), key.displayString, name), for: action)
        case .otherAction:
            finish(action)
            reassignment = ShortcutReassignment(
                action: action,
                key: key,
                holders: settings.conflicts(for: key, excluding: action, enabledModules: AppModule.storedEnabledModules())
            )
        case .none:
            finish(action)
            keyboard.value = settings.assigning(key, to: action)
        }
    }

    private func refuse(_ message: String, for action: ShortcutAction) {
        feedback = ShortcutRecordingFeedback(action: action, message: message)
        signalRefusal(message)
    }

    private func finish(_ action: ShortcutAction) {
        cancel()
        if feedback?.action == action {
            feedback = nil
        }
    }
}
