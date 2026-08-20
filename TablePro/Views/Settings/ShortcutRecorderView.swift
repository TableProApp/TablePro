//
//  ShortcutRecorderView.swift
//  TablePro
//
//  Press-to-record keyboard shortcut capture component.
//

import AppKit
import SwiftUI

// MARK: - ShortcutRecorderNSView

/// AppKit NSView that captures keyboard shortcuts via press-to-record interaction
final class ShortcutRecorderNSView: NSView {
    /// Callback when a valid shortcut is recorded
    var onRecord: ((BoundKey) -> Void)?

    /// Callback when the shortcut is cleared (Delete key while recording)
    var onClear: (() -> Void)?

    /// The currently displayed key combo
    var currentCombo: BoundKey? {
        didSet {
            needsDisplay = true
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    /// Whether the view is currently in recording mode
    private var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            if isRecording { startRecordingMonitor() } else { stopRecordingMonitor() }
            needsDisplay = true
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    /// A menu key equivalent is consumed in `sendEvent` before the responder chain runs, so
    /// `keyDown` never sees Command W and the menu command fires instead of being recorded. A
    /// local monitor runs earlier than menu dispatch, which is the only place the key is still
    /// interceptable.
    private var recordingMonitor: Any?

    /// Currently held modifier flags during recording (for live display)
    private var activeModifiers: NSEvent.ModifierFlags = []

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        focusRingType = .exterior
        setAccessibilityRole(.button)
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool { true }

    /// Focus alone does not start recording. Full Keyboard Access moves focus with Tab, and
    /// arming on focus swallowed that Tab and trapped the user in this field. Recording
    /// starts on a deliberate click, Space, Return, or an accessibility press.
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            activeModifiers = []
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            isRecording = false
            activeModifiers = []
        }
        return result
    }

    // MARK: - Mouse Handling

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
    }

    // MARK: - Keyboard Handling

    override func keyDown(with event: NSEvent) {
        guard !isRecording else { return }
        let isActivation = event.keyCode == KeyCode.space.rawValue
            || event.keyCode == KeyCode.return.rawValue
        guard isActivation else {
            super.keyDown(with: event)
            return
        }
        activeModifiers = []
        isRecording = true
    }

    private func startRecordingMonitor() {
        guard recordingMonitor == nil else { return }
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handleRecordingEvent(event)
        }
    }

    private func stopRecordingMonitor() {
        guard let monitor = recordingMonitor else { return }
        NSEvent.removeMonitor(monitor)
        recordingMonitor = nil
    }

    /// A local monitor is app-wide, so anything arriving while this view's window is not key
    /// belongs to another window and has to pass through untouched.
    func handleRecordingEvent(_ event: NSEvent) -> NSEvent? {
        guard isRecording, window?.isKeyWindow == true else { return event }
        guard event.type != .flagsChanged else {
            activeModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            needsDisplay = true
            return nil
        }

        let isBareKey = !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.control)

        if event.keyCode == KeyCode.escape.rawValue, isBareKey {
            endRecording()
            return nil
        }
        if event.keyCode == KeyCode.delete.rawValue, isBareKey {
            onClear?()
            endRecording()
            return nil
        }
        guard let combo = BoundKey(from: event) else {
            NSSound.beep()
            return nil
        }
        onRecord?(combo)
        endRecording()
        return nil
    }

    private func endRecording() {
        isRecording = false
        activeModifiers = []
        window?.makeFirstResponder(nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil else { return }
        isRecording = false
    }

    deinit {
        guard let monitor = recordingMonitor else { return }
        NSEvent.removeMonitor(monitor)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        let isArmed = isRecording && window?.isKeyWindow == true && NSApp.isActive

        if isArmed {
            NSColor.controlAccentColor.withAlphaComponent(0.1).setFill()
        } else {
            NSColor.controlBackgroundColor.setFill()
        }
        let bgPath = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        bgPath.fill()

        if isArmed {
            NSColor.controlAccentColor.setStroke()
        } else {
            NSColor.separatorColor.setStroke()
        }
        let borderPath = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 6,
            yRadius: 6
        )
        borderPath.lineWidth = isArmed ? 2.0 : 1.0
        borderPath.stroke()

        let text = displayText
        let textColor: NSColor = isRecording ? .secondaryLabelColor : .labelColor
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        let attrString = NSAttributedString(string: text, attributes: attributes)
        let textSize = attrString.size()
        let textRect = NSRect(
            x: (bounds.width - textSize.width) / 2,
            y: (bounds.height - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
        attrString.draw(in: textRect)
    }

    /// The text to display in the view
    private var displayText: String {
        if isRecording {
            let modifierString = modifierDisplayString
            if modifierString.isEmpty {
                return String(localized: "Type shortcut...")
            }
            return modifierString
        }

        if let combo = currentCombo, !combo.isCleared {
            return combo.displayString
        }
        return String(localized: "None")
    }

    /// Build modifier display string from currently held modifiers
    private var modifierDisplayString: String {
        var parts: [String] = []
        if activeModifiers.contains(.control) { parts.append("⌃") }
        if activeModifiers.contains(.option) { parts.append("⌥") }
        if activeModifiers.contains(.shift) { parts.append("⇧") }
        if activeModifiers.contains(.command) { parts.append("⌘") }
        return parts.joined()
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func accessibilityLabel() -> String? {
        String(localized: "Shortcut recorder")
    }

    override func accessibilityValue() -> Any? {
        if isRecording {
            return String(localized: "Recording shortcut")
        }
        if let combo = currentCombo, !combo.isCleared {
            return combo.displayString
        }
        return String(localized: "None")
    }

    override func accessibilityPerformPress() -> Bool {
        window?.makeFirstResponder(self)
        isRecording = true
        return true
    }

    // MARK: - Intrinsic Size

    override var intrinsicContentSize: NSSize {
        NSSize(width: 160, height: 24)
    }
}

// MARK: - ShortcutRecorderView (SwiftUI Wrapper)

/// SwiftUI wrapper for the AppKit shortcut recorder
struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var combo: BoundKey?

    /// Called when a new combo is recorded (before setting binding)
    var onRecord: ((BoundKey) -> Void)?

    /// Called when the shortcut is cleared
    var onClear: (() -> Void)?

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        let view = ShortcutRecorderNSView()
        view.currentCombo = combo
        view.onRecord = { newCombo in
            onRecord?(newCombo)
        }
        view.onClear = {
            onClear?()
        }
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderNSView, context: Context) {
        nsView.currentCombo = combo
        nsView.onRecord = { [onRecord] newCombo in onRecord?(newCombo) }
        nsView.onClear = { [onClear] in onClear?() }
    }
}
