import AppKit
import SwiftUI

struct ShortcutRecorderLook: Equatable {
    let title: String
    let isPlaceholder: Bool
    let isArmed: Bool
    let accessibilityValue: String

    init(key: BoundKey?, isArmed: Bool, heldModifiers: NSEvent.ModifierFlags) {
        self.isArmed = isArmed
        if isArmed {
            let held = Self.glyphs(for: heldModifiers)
            title = held.isEmpty ? String(localized: "Type Shortcut") : held
            isPlaceholder = false
            accessibilityValue = String(localized: "Recording")
        } else if let key, !key.isCleared {
            title = key.displayString
            isPlaceholder = false
            accessibilityValue = key.displayString
        } else {
            title = String(localized: "None")
            isPlaceholder = true
            accessibilityValue = title
        }
    }

    static func glyphs(for flags: NSEvent.ModifierFlags) -> String {
        var glyphs = ""
        if flags.contains(.control) { glyphs += "⌃" }
        if flags.contains(.option) { glyphs += "⌥" }
        if flags.contains(.shift) { glyphs += "⇧" }
        if flags.contains(.command) { glyphs += "⌘" }
        return glyphs
    }
}

// AppKit so one control carries the key title, the armed look and its accessibility value; SwiftUI bordered buttons ignore foregroundStyle.
final class ShortcutRecorderButton: NSButton {
    private static let minimumWidth: CGFloat = 112

    private(set) var shortcutAction: ShortcutAction?
    private weak var session: ShortcutRecordingSession?
    private var look: ShortcutRecorderLook?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Momentary push in every state, so the role stays AXButton; a toggle type reads as a checkbox.
        setButtonType(.momentaryPushIn)
        bezelStyle = .push
        font = .systemFont(ofSize: NSFont.systemFontSize)
        setContentHuggingPriority(.required, for: .horizontal)
        target = self
        action = #selector(press(_:))
        let help = String(localized: "Press to record a new shortcut. Delete removes it, Escape cancels.")
        toolTip = help
        setAccessibilityHelp(help)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width = max(size.width, Self.minimumWidth)
        return size
    }

    // Return goes to the window's default button unless the focused recorder claims it.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == KeyCode.return.rawValue || event.keyCode == KeyCode.enter.rawValue {
            performClick(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    func configure(action: ShortcutAction, session: ShortcutRecordingSession) {
        self.session = session
        guard shortcutAction != action else { return }
        shortcutAction = action
        setAccessibilityLabel(action.displayName)
        setAccessibilityIdentifier("shortcut-recorder-\(action.rawValue)")
    }

    func apply(_ wanted: ShortcutRecorderLook) {
        let current = look
        guard wanted != current else { return }
        look = wanted
        if wanted.title != current?.title || wanted.isPlaceholder != current?.isPlaceholder {
            if wanted.isPlaceholder {
                attributedTitle = Self.placeholderTitle(wanted.title)
            } else {
                title = wanted.title
            }
            invalidateIntrinsicContentSize()
        }
        if wanted.isArmed != current?.isArmed {
            bezelColor = wanted.isArmed ? .controlAccentColor : nil
        }
        if wanted.accessibilityValue != current?.accessibilityValue {
            setAccessibilityValue(wanted.accessibilityValue)
            if current != nil {
                NSAccessibility.post(element: self, notification: .valueChanged)
            }
        }
    }

    func cancelOwnRecording() {
        guard let shortcutAction, let session, session.recording == shortcutAction else { return }
        session.cancel()
    }

    @objc private func press(_ sender: Any?) {
        guard let shortcutAction else { return }
        session?.toggle(shortcutAction, anchor: self)
    }

    private static func placeholderTitle(_ title: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .paragraphStyle: paragraph,
        ])
    }
}

struct ShortcutRecorderField: NSViewRepresentable {
    let action: ShortcutAction
    let key: BoundKey?
    let isArmed: Bool
    let heldModifiers: NSEvent.ModifierFlags
    let session: ShortcutRecordingSession

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton(frame: .zero)
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.configure(action: action, session: session)
        button.apply(ShortcutRecorderLook(key: key, isArmed: isArmed, heldModifiers: heldModifiers))
    }

    static func dismantleNSView(_ button: ShortcutRecorderButton, coordinator: Void) {
        button.cancelOwnRecording()
    }
}
