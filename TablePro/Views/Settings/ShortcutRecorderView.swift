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
    var onRecord: ((KeyCombo) -> Void)?

    /// Callback when the shortcut is cleared (Delete key while recording)
    var onClear: (() -> Void)?

    /// The currently displayed key combo
    var currentCombo: KeyCombo? {
        didSet { needsDisplay = true }
    }

    /// Whether the view is currently in recording mode
    private var isRecording = false {
        didSet { needsDisplay = true }
    }

    /// Currently held modifier flags during recording (for live display)
    private var activeModifiers: NSEvent.ModifierFlags = []

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            isRecording = true
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
        if !isRecording {
            window?.makeFirstResponder(self)
        }
    }

    // MARK: - Keyboard Handling

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return }

        // Escape cancels recording
        if event.keyCode == 53
            && !event.modifierFlags.contains(.command)
            && !event.modifierFlags.contains(.control)
        {
            window?.makeFirstResponder(nil)
            return
        }

        // Delete/Backspace clears the shortcut
        if event.keyCode == 51
            && !event.modifierFlags.contains(.command)
            && !event.modifierFlags.contains(.control)
        {
            onClear?()
            window?.makeFirstResponder(nil)
            return
        }

        // Try to create a KeyCombo from the event
        if let combo = KeyCombo(from: event) {
            onRecord?(combo)
            window?.makeFirstResponder(nil)
        } else {
            NSSound.beep()
        }
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return }
        activeModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds

        // Background
        if isRecording {
            NSColor.controlAccentColor.withAlphaComponent(0.1).setFill()
        } else {
            NSColor.controlBackgroundColor.setFill()
        }
        let bgPath = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        bgPath.fill()

        // Border
        if isRecording {
            NSColor.controlAccentColor.setStroke()
        } else {
            NSColor.separatorColor.setStroke()
        }
        let borderPath = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 6,
            yRadius: 6
        )
        borderPath.lineWidth = isRecording ? 2.0 : 1.0
        borderPath.stroke()

        // Text
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
            // Show live modifier display or placeholder
            let modifierString = modifierDisplayString
            if modifierString.isEmpty {
                return String(localized: "Type shortcut...")
            }
            return modifierString
        }

        // Not recording — show current shortcut or "None"
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
    @Binding var combo: KeyCombo?

    /// Called when a new combo is recorded (before setting binding)
    var onRecord: ((KeyCombo) -> Void)?

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
