//
//  DataGridEditingCellView.swift
//  TablePro
//

import AppKit
import TableProTheme

// The one cell view the grid mounts, for the edited cell; every other cell is drawn (probe P1a, P1b).
@MainActor
final class DataGridEditingCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("data-grid-edit-cell")

    private static let borderWidth: CGFloat = 2

    let field = DataGridEditingTextField(frame: .zero)
    private var scope: ThemeScope = .live

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        // Its own layer: the row view draws its subviews into one layer, which would flatten the caret.
        wantsLayer = true
        field.autoresizingMask = []
        addSubview(field)
        textField = field
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func prepare(text: String, font: NSFont, scope: ThemeScope, columnName: String, delegate: any NSTextFieldDelegate) {
        self.scope = scope
        let palette = scope.palette
        field.adopt(scope)
        field.font = font
        field.textColor = palette.color(.editorText, otherwise: .textColor)
        field.backgroundColor = palette.color(.editorBackground, otherwise: .textBackgroundColor)
        field.stringValue = text
        field.delegate = delegate
        // A text field's accessibility element is its cell; a label set on the control never reaches VoiceOver (measured).
        field.cell?.setAccessibilityLabel(columnName)
        needsLayout = true
        needsDisplay = true
    }

    // Centred like the drawn text, which a field the cell's height would draw above.
    func layoutField() {
        let inset = Self.borderWidth
        let lineHeight = field.font.map { ($0.ascender - $0.descender + $0.leading).rounded(.up) } ?? bounds.height
        let height = min(lineHeight + 2, max(0, bounds.height - 2 * inset))
        let frame = NSRect(
            x: inset,
            y: ((bounds.height - height) / 2).rounded(),
            width: max(0, bounds.width - 2 * inset),
            height: height
        )
        if field.frame != frame {
            field.frame = frame
        }
    }

    override func layout() {
        super.layout()
        layoutField()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutField()
    }

    override var isFlipped: Bool { true }

    // A selected row's emphasized style would turn the text white on the field's own white background.
    override var backgroundStyle: NSView.BackgroundStyle {
        get { .normal }
        set { super.backgroundStyle = newValue == .emphasized ? .normal : newValue }
    }

    // The row skips the active-cell border under the edited cell, so the editor draws it.
    override func draw(_ dirtyRect: NSRect) {
        scope.palette.color(.editorBackground, otherwise: .textBackgroundColor).setFill()
        bounds.fill()
        let path = NSBezierPath(rect: bounds.insetBy(dx: Self.borderWidth / 2, dy: Self.borderWidth / 2))
        path.lineWidth = Self.borderWidth
        scope.palette[.gridFocusBorder].setStroke()
        path.stroke()
    }
}

// Its own field editor: a caret color written to the window's shared one stays on the next field edited (measured).
@MainActor
final class DataGridEditingTextField: NSTextField {
    private(set) lazy var ownFieldEditor: NSTextView = {
        let editor = DataGridFieldEditor()
        editor.isFieldEditor = true
        editor.allowsUndo = true
        TextValueEditor.disableSubstitutions(in: editor)
        return editor
    }()

    // Held, or its theme subscription stops at the first change.
    private var fieldEditorStyle: ThemeTextViewStyle?
    private var invisibleCharacters: InvisibleCharacterTextDisplay?

    override class var cellClass: AnyClass? {
        get { DataGridEditingTextFieldCell.self }
        set { super.cellClass = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = true
        isSelectable = true
        isBordered = false
        isBezeled = false
        drawsBackground = true
        focusRingType = .none
        usesSingleLineMode = true
        lineBreakMode = .byClipping
        maximumNumberOfLines = 1
        allowsEditingTextAttributes = false
        importsGraphics = false
        cell?.wraps = false
        cell?.isScrollable = true
        cell?.setAccessibilityIdentifier("data-grid-edit-field")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func adopt(_ scope: ThemeScope) {
        guard fieldEditorStyle?.scope !== scope else { return }
        fieldEditorStyle?.detach()
        fieldEditorStyle = ThemeTextViewStyle(textView: ownFieldEditor, scope: scope)
    }

    // AppKit resets the editor's colors from the cell each time editing starts.
    fileprivate func fieldEditorDidSetUp() {
        fieldEditorStyle?.apply()
        let marksInvisibles = AppSettingsManager.shared.dataGrid.showInvisibleCharacters
        if let invisibleCharacters {
            invisibleCharacters.isEnabled = marksInvisibles
        } else {
            invisibleCharacters = InvisibleCharacterTextDisplay.install(on: ownFieldEditor, isEnabled: marksInvisibles)
        }
    }
}

// Holds no state of its own: AppKit copies a cell bit for bit, so everything lives on the field.
private final class DataGridEditingTextFieldCell: NSTextFieldCell {
    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        (controlView as? DataGridEditingTextField)?.ownFieldEditor
    }

    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let configured = super.setUpFieldEditorAttributes(textObj)
        (controlView as? DataGridEditingTextField)?.fieldEditorDidSetUp()
        return configured
    }

    override func endEditing(_ textObj: NSText) {
        (textObj as? DataGridFieldEditor)?.endUndoSession()
        super.endEditing(textObj)
    }
}

// The window's undo manager would keep typing actions into text AppKit empties at the end, and Undo would raise.
private final class DataGridFieldEditor: NSTextView {
    private let sessionUndoManager = UndoManager()

    override var undoManager: UndoManager? {
        sessionUndoManager
    }

    func endUndoSession() {
        sessionUndoManager.removeAllActions()
    }

    // Paste, drop and Services read here; single-line mode would drop the text's line breaks.
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let range = rangeForUserTextChange
        if range.location != NSNotFound,
           let text = pboard.string(forType: .string), text.contains(where: \.isNewline),
           let fieldDelegate = (delegate as? NSTextField)?.delegate as? DataGridFieldEditorDelegate,
           fieldDelegate.fieldEditorInsertsLines(text, replacing: range) {
            return true
        }
        return super.readSelection(from: pboard, type: type)
    }
}
