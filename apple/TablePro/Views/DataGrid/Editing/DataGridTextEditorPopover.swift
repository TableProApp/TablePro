//
//  DataGridTextEditorPopover.swift
//  TablePro
//

import AppKit
import TableProTheme

// The field editor cannot grow past its row, so a multi-line or long value edits here; read-only, it is the viewer.
@MainActor
final class DataGridTextEditorPopover: NSObject, NSPopoverDelegate, NSTextViewDelegate {
    enum Ending: Equatable {
        case commit(CellEditorMovement?)
        case cancel
    }

    // Wrapping lays a paragraph out whole first: 206 ms at 256 KB and 816 ms at 1 MB, 7 ms unwrapped (#2381).
    static let wrapLimit = 65_536

    private static let minimumWidth: CGFloat = 320
    private static let maximumWidth: CGFloat = 560
    private static let minimumHeight: CGFloat = 80
    private static let maximumHeight: CGFloat = 360

    let popover = NSPopover()
    let textView: DataGridPopoverTextView
    let isEditable: Bool
    var onEnd: ((Ending, String) -> Void)?

    private var hasEnded = false
    // Held, or their subscriptions stop at the first change.
    private var style: ThemeTextViewStyle?
    private var invisibleCharacters: InvisibleCharacterTextDisplay?

    init(text: String, isEditable: Bool, cellWidth: CGFloat, scope: ThemeScope) {
        self.isEditable = isEditable
        let font = ThemeEngine.shared.dataGridFonts.regular
        let size = Self.contentSize(for: text, cellWidth: cellWidth, font: font)
        let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = scope.palette.color(.editorBackground, otherwise: .textBackgroundColor)
        scrollView.autoresizingMask = [.width, .height]

        let textView = DataGridPopoverTextView(usingTextLayoutManager: true)
        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.importsGraphics = false
        TextValueEditor.disableSubstitutions(in: textView)
        textView.font = font
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 4, height: 6)
        Self.applyLayout(to: textView, for: text, width: scrollView.contentSize.width)
        scrollView.hasHorizontalScroller = !Self.wraps(text)
        self.textView = textView
        super.init()

        textView.editorPopover = self
        style = ThemeTextViewStyle(textView: textView, scope: scope)
        invisibleCharacters = InvisibleCharacterTextDisplay.install(
            on: textView,
            isEnabled: AppSettingsManager.shared.dataGrid.showInvisibleCharacters
        )
        textView.string = text
        textView.delegate = self
        textView.setAccessibilityIdentifier(isEditable ? "grid-text-editor" : "grid-text-viewer")
        scrollView.documentView = textView

        let controller = NSViewController()
        controller.view = scrollView
        popover.contentViewController = controller
        popover.contentSize = size
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
    }

    static func wraps(_ text: String) -> Bool {
        (text as NSString).length <= wrapLimit
    }

    // maxSize stays unbounded, or a long line is clipped at the popover's edge instead of scrolling.
    static func applyLayout(to textView: NSTextView, for text: String, width: CGFloat) {
        let unbounded = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = .zero
        textView.maxSize = unbounded
        textView.isVerticallyResizable = true
        let wrapping = wraps(text)
        textView.isHorizontallyResizable = !wrapping
        textView.autoresizingMask = wrapping ? [.width] : []
        textView.textContainer?.widthTracksTextView = wrapping
        textView.textContainer?.containerSize = wrapping
            ? NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            : unbounded
    }

    static func contentSize(for text: String, cellWidth: CGFloat, font: NSFont) -> NSSize {
        let width = min(max(cellWidth, minimumWidth), maximumWidth)
        let lineHeight = (font.ascender - font.descender + font.leading).rounded(.up)
        var lines = 1
        let scalars = text.unicodeScalars
        var previous: Unicode.Scalar?
        for scalar in scalars where lines < 40 {
            if scalar == "\r" || (scalar == "\n" && previous != "\r") {
                lines += 1
            }
            previous = scalar
        }
        let characterWidth = max(1, ("0" as NSString).size(withAttributes: [.font: font]).width)
        let charactersPerLine = max(1, Int((width - 16) / characterWidth))
        let wrappedLines = wraps(text) ? (text.utf16.count / charactersPerLine) : 0
        let height = CGFloat(lines + wrappedLines) * lineHeight + 16
        return NSSize(width: width, height: min(max(height, minimumHeight), maximumHeight))
    }

    func show(relativeTo rect: NSRect, of view: NSView, selection: NSRange?) {
        // A window off screen has no place on screen to point the popover at.
        if view.window?.isVisible == true {
            popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
            textView.window?.makeFirstResponder(textView)
        }
        let length = (textView.string as NSString).length
        if let selection {
            let location = min(max(selection.location, 0), length)
            textView.setSelectedRange(NSRange(location: location, length: min(max(selection.length, 0), length - location)))
        } else if isEditable {
            textView.selectAll(nil)
        }
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    var isShown: Bool { popover.isShown && !hasEnded }

    func end(_ ending: Ending) {
        guard !hasEnded else { return }
        hasEnded = true
        let text = textView.string
        style?.detach()
        style = nil
        invisibleCharacters = nil
        popover.close()
        onEnd?(ending, text)
        onEnd = nil
    }

    // A click outside or an app switch closes it; what was typed is kept, as when focus leaves a field.
    func popoverDidClose(_ notification: Notification) {
        end(isEditable ? .commit(nil) : .cancel)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            end(isEditable ? .commit(nil) : .cancel)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            end(.cancel)
            return true
        case #selector(NSResponder.insertTab(_:)):
            return leave(.tab, from: textView)
        case #selector(NSResponder.insertBacktab(_:)):
            return leave(.backtab, from: textView)
        case #selector(NSResponder.moveUp(_:)):
            return leaveVertically(.up, from: textView)
        case #selector(NSResponder.moveDown(_:)):
            return leaveVertically(.down, from: textView)
        default:
            return false
        }
    }

    // An arrow during an IME composition moves through the composition.
    private func leaveVertically(_ movement: CellEditorMovement, from textView: NSTextView) -> Bool {
        guard isEditable, !textView.hasMarkedText() else { return false }
        let exit = CellEditorArrowExit(text: textView.string as NSString, selection: textView.selectedRange())
        guard movement == .up ? exit.canExitUp : exit.canExitDown else { return false }
        end(.commit(movement))
        return true
    }

    // A literal tab is not what Tab was pressed for, so a composition swallows it.
    private func leave(_ movement: CellEditorMovement, from textView: NSTextView) -> Bool {
        guard !textView.hasMarkedText() else { return true }
        end(isEditable ? .commit(movement) : .cancel)
        return true
    }
}

// Typing undo stays here, apart from the window's history of committed edits.
@MainActor
final class DataGridPopoverTextView: NSTextView {
    private let storedUndoManager = UndoManager()

    weak var editorPopover: DataGridTextEditorPopover?

    override var undoManager: UndoManager? { storedUndoManager }

    // Cmd+S saves what is typed: commit first, then let Save run.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if modifiers == .command, event.charactersIgnoringModifiers == "s", let editorPopover, editorPopover.isEditable {
            editorPopover.end(.commit(nil))
            return false
        }
        return super.performKeyEquivalent(with: event)
    }
}
