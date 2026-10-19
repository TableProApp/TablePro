import AppKit
import Combine
import SwiftUI
import TableProTheme

/// An editable stored value, drawn in the same value well as a read-only or multi-line value.
///
/// A bezeled field paints its own fill and turns `drawsBackground` off, so no theme color reaches
/// it, and it edits in the window's shared field editor, so neither does the theme's caret. This
/// field is borderless and fills the well; its cell insets the text, rings the well with the
/// system focus ring and hands out a field editor of its own.
internal struct ValueTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var font: NSFont
    /// Nil keeps one line. A range wraps and grows between those line counts, then scrolls.
    var lineLimit: ClosedRange<Int>?

    func makeNSView(context: Context) -> ValueTextFieldView {
        let field = ValueTextFieldView(string: text)
        field.delegate = context.coordinator
        context.coordinator.lastAppliedText = text
        configure(field, isEnabled: context.environment.isEnabled)
        return field
    }

    func updateNSView(_ field: ValueTextFieldView, context: Context) {
        context.coordinator.text = $text
        configure(field, isEnabled: context.environment.isEnabled)

        guard context.coordinator.lastAppliedText != text else { return }
        context.coordinator.lastAppliedText = text
        field.replaceText(with: text)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: ValueTextFieldView, context: Context) -> CGSize? {
        let width = proposal.width ?? field.fittingSize.width
        return CGSize(width: width, height: field.height(forWidth: width, lineLimit: lineLimit))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    private func configure(_ field: ValueTextFieldView, isEnabled: Bool) {
        if field.font != font {
            field.font = font
            field.invalidateIntrinsicContentSize()
        }
        if field.placeholderString != placeholder {
            field.placeholderString = placeholder
        }
        if field.isEnabled != isEnabled {
            field.isEnabled = isEnabled
        }
        field.setWraps(lineLimit != nil)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        /// What the field was last given, so an update pass that carries the field's own edit back
        /// does not reset the caret.
        var lastAppliedText = ""

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? ValueTextFieldView else { return }
            let value = field.stringValue
            lastAppliedText = value
            text.wrappedValue = value
            field.invalidateIntrinsicContentSize()
        }
    }
}

internal final class ValueTextFieldView: NSTextField {
    /// Its own, because the window's field editor is shared: a caret color written there stays on
    /// the next field the user edits, measured.
    internal private(set) lazy var ownFieldEditor: NSTextView = {
        let editor = ValueFieldEditor()
        editor.isFieldEditor = true
        editor.allowsUndo = true
        TextValueEditor.disableSubstitutions(in: editor)
        return editor
    }()

    fileprivate private(set) lazy var fieldEditorStyle = ThemeTextViewStyle(textView: ownFieldEditor)
    private var themeCancellable: AnyCancellable?

    override class var cellClass: AnyClass? {
        get { ValueTextFieldCell.self }
        set { super.cellClass = newValue }
    }

    convenience init(string: String) {
        self.init(frame: .zero)
        stringValue = string
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBezeled = false
        isBordered = false
        drawsBackground = false
        isEditable = true
        isSelectable = true
        focusRingType = .default
        textColor = ThemeScope.live.palette.color(.editorText, otherwise: .textColor)
        // The color is dynamic and answers for the theme in effect, but nothing asks it again
        // until the field draws.
        themeCancellable = ThemeScope.live.changes
            .sink { [weak self] _ in self?.needsDisplay = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// A borderless field reports 2pt side insets, so SwiftUI would lay it out 4pt wider than the
    /// well and its focus ring would miss the well's edge.
    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsetsZero
    }

    /// A value set from outside while the field is being edited, such as Set EMPTY from its menu.
    internal func replaceText(with text: String) {
        defer { invalidateIntrinsicContentSize() }
        guard let editor = currentEditor() as? NSTextView else {
            stringValue = text
            return
        }
        let caret = editor.selectedRange().location
        editor.string = text
        editor.setSelectedRange(NSRange(location: min(caret, (text as NSString).length), length: 0))
        // Typing undo indexes into the text it was recorded against; undoing it here would raise.
        editor.undoManager?.removeAllActions()
    }

    internal func setWraps(_ wraps: Bool) {
        guard let cell = cell as? ValueTextFieldCell, cell.wraps != wraps || cell.usesSingleLineMode == wraps else { return }
        cell.usesSingleLineMode = !wraps
        cell.wraps = wraps
        cell.isScrollable = !wraps
        cell.lineBreakMode = wraps ? .byCharWrapping : .byTruncatingTail
        invalidateIntrinsicContentSize()
    }

    internal func height(forWidth width: CGFloat, lineLimit: ClosedRange<Int>?) -> CGFloat {
        guard let cell else { return intrinsicContentSize.height }
        let inset = ValueWellMetrics.textInset.height * 2
        guard let lineLimit, let font else {
            return ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)).height)
        }
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let fitting = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: CGFloat.greatestFiniteMagnitude)).height
        let lowest = lineHeight * CGFloat(lineLimit.lowerBound) + inset
        let highest = lineHeight * CGFloat(lineLimit.upperBound) + inset
        return ceil(min(max(fitting, lowest), highest))
    }
}

/// Holds no state of its own: AppKit copies a cell bit for bit, so everything lives on the field.
private final class ValueTextFieldCell: NSTextFieldCell {
    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        (controlView as? ValueTextFieldView)?.ownFieldEditor
    }

    /// AppKit resets the editor's colors from the cell each time editing starts.
    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let configured = super.setUpFieldEditorAttributes(textObj)
        (controlView as? ValueTextFieldView)?.fieldEditorStyle.apply()
        return configured
    }

    override func endEditing(_ textObj: NSText) {
        (textObj as? ValueFieldEditor)?.endUndoSession()
        super.endEditing(textObj)
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        super.drawingRect(forBounds: Self.textRect(in: rect))
    }

    override func cellSize(forBounds rect: NSRect) -> NSSize {
        let inset = ValueWellMetrics.textInset
        let text = super.cellSize(forBounds: Self.textRect(in: rect))
        return NSSize(width: text.width + inset.width * 2, height: text.height + inset.height * 2)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: Self.textRect(in: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: Self.textRect(in: rect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
    }

    override func drawFocusRingMask(withFrame cellFrame: NSRect, in controlView: NSView) {
        let radius = ValueWellMetrics.cornerRadius
        NSBezierPath(roundedRect: cellFrame, xRadius: radius, yRadius: radius).fill()
    }

    override func focusRingMaskBounds(forFrame cellFrame: NSRect, in controlView: NSView) -> NSRect {
        cellFrame
    }

    private static func textRect(in rect: NSRect) -> NSRect {
        let inset = ValueWellMetrics.textInset
        guard rect.width.isFinite, rect.height.isFinite else { return rect }
        return rect.insetBy(dx: inset.width, dy: inset.height)
    }
}

/// The system field editor keeps typing undo in a manager of its own for one editing session. A
/// custom one would resolve the window's instead, shared with the grid, and leave a typing action
/// pointing into a text that AppKit empties when editing ends: Undo then raises, measured.
private final class ValueFieldEditor: NSTextView {
    private let sessionUndoManager = UndoManager()

    override var undoManager: UndoManager? {
        sessionUndoManager
    }

    func endUndoSession() {
        sessionUndoManager.removeAllActions()
    }
}
