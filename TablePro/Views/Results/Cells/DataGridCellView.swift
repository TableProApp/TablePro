//
//  DataGridCellView.swift
//  TablePro
//

import AppKit

@MainActor
final class DataGridCellView: NSView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("dataCell")

    weak var accessoryDelegate: DataGridCellAccessoryDelegate?
    var nullDisplayString: String = ""

    private(set) var kind: DataGridCellKind = .text
    private(set) var cellRow: Int = -1
    private(set) var cellColumnIndex: Int = -1

    private var displayText: String = ""
    private var rawValue: String?
    private var placeholder: DataGridCellPlaceholder?
    private var isLargeDataset: Bool = false
    private var isEditableCell: Bool = false

    private var textFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    private var textColor: NSColor = .labelColor
    private var modifiedColumnTint: NSColor?

    private var visualState: RowVisualState = .empty
    private var isFocusedCell: Bool = false
    private var onEmphasizedSelection: Bool = false
    private var hasOverlay: Bool = false
    private var findMatchTint: NSColor?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
    }

    override var allowsVibrancy: Bool { false }
    override var isFlipped: Bool { true }

    func configure(
        kind: DataGridCellKind,
        content: DataGridCellContent,
        state: DataGridCellState,
        palette: DataGridCellPalette
    ) {
        var needsRedraw = false

        if self.kind != kind {
            self.kind = kind
            needsRedraw = true
        }
        cellRow = state.row
        cellColumnIndex = state.columnIndex

        if hasOverlay {
            hasOverlay = false
            updateFocusPresentation()
            needsRedraw = true
        }

        let nextFont: NSFont
        let nextColor: NSColor
        let deletedTextColor = state.visualState.isDeleted ? palette.deletedRowText : nil

        switch content.placeholder {
        case .none:
            nextFont = palette.regularFont
            nextColor = deletedTextColor ?? .labelColor
        case .null:
            nextFont = palette.italicFont
            nextColor = deletedTextColor ?? .secondaryLabelColor
        case .empty:
            nextFont = palette.italicFont
            nextColor = deletedTextColor ?? .secondaryLabelColor
        case .defaultMarker:
            nextFont = palette.mediumFont
            nextColor = deletedTextColor ?? .systemBlue
        }
        let nextDisplayText = DataGridCellContent.resolvedDisplayText(
            content.displayText,
            placeholder: content.placeholder,
            isLargeDataset: state.isLargeDataset,
            nullDisplayString: nullDisplayString
        )

        if displayText != nextDisplayText
            || textFont != nextFont
            || textColor != nextColor {
            displayText = nextDisplayText
            textFont = nextFont
            textColor = nextColor
            needsRedraw = true
        }

        if rawValue != content.rawValue {
            rawValue = content.rawValue
            needsRedraw = true
        }
        placeholder = content.placeholder
        isLargeDataset = state.isLargeDataset
        if isEditableCell != state.isEditable {
            isEditableCell = state.isEditable
            needsRedraw = true
        }

        let nextTint: NSColor?
        if state.visualState.isDeleted || state.visualState.isInserted {
            nextTint = nil
        } else if state.visualState.isModified(columnIndex: state.columnIndex) {
            nextTint = palette.modifiedColumnTint
        } else {
            nextTint = nil
        }
        if !colorsEqual(modifiedColumnTint, nextTint) {
            modifiedColumnTint = nextTint
            needsRedraw = true
        }

        let nextFindTint: NSColor? = state.isCurrentFindMatch ? palette.findMatchTint : nil
        if !colorsEqual(findMatchTint, nextFindTint) {
            findMatchTint = nextFindTint
            needsRedraw = true
        }

        if visualState != state.visualState {
            visualState = state.visualState
            needsRedraw = true
        }
        if isFocusedCell != state.isFocused {
            isFocusedCell = state.isFocused
            updateFocusPresentation()
            needsRedraw = true
        }
        setAccessibilityRowIndexRange(NSRange(location: state.row, length: 1))
        setAccessibilityColumnIndexRange(NSRange(location: state.columnIndex, length: 1))

        if needsRedraw {
            needsDisplay = true
        }
    }

    override func accessibilityValue() -> Any? {
        accessibilityText
    }

    override func accessibilityLabel() -> String? {
        String(
            format: String(localized: "Row %d, column %d: %@"),
            cellRow + 1,
            cellColumnIndex + 1,
            accessibilityText
        )
    }

    private var accessibilityText: String {
        switch placeholder {
        case .none:
            return displayText
        case .null:
            return displayText.isEmpty ? String(localized: "NULL") : displayText
        case .empty:
            return displayText.isEmpty ? String(localized: "Empty") : displayText
        case .defaultMarker:
            return displayText.isEmpty ? String(localized: "DEFAULT") : displayText
        }
    }

    func applyEmphasizedSelection(_ value: Bool) {
        guard onEmphasizedSelection != value else { return }
        onEmphasizedSelection = value
        updateFocusPresentation()
    }

    func applyOverlayActive(_ value: Bool) {
        guard hasOverlay != value else { return }
        hasOverlay = value
        updateFocusPresentation()
        needsDisplay = true
    }

    private func updateFocusPresentation() {
        let shouldShowRing = isFocusedCell && !onEmphasizedSelection && !hasOverlay
        focusRingType = shouldShowRing ? .exterior : .none
        noteFocusRingMaskChanged()
        needsDisplay = true
    }

    override var focusRingMaskBounds: NSRect {
        (onEmphasizedSelection || hasOverlay) ? .zero : bounds
    }

    override func drawFocusRingMask() {
        guard !onEmphasizedSelection, !hasOverlay else { return }
        NSBezierPath(rect: bounds).fill()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    /// Drawn through the same renderer the row view uses, so a mounted cell and a drawn one cannot
    /// diverge. AppKit still draws this view's focus ring, so the appearance's own ring stands down.
    override func draw(_ dirtyRect: NSRect) {
        var appearance = currentAppearance()
        appearance = DataGridCellAppearance(
            text: appearance.text,
            font: appearance.font,
            textColor: appearance.textColor,
            backgroundTint: appearance.backgroundTint,
            accessory: appearance.accessory,
            accessoryRole: appearance.accessoryRole,
            drawsFocusBorder: appearance.drawsFocusBorder,
            drawsFocusRing: false
        )
        Self.renderer.draw(appearance, in: bounds)
    }

    private static let renderer = DataGridCellRenderer()

    private func currentAppearance() -> DataGridCellAppearance {
        DataGridCellAppearance(
            text: displayText,
            font: textFont,
            textColor: resolvedTextColor(),
            backgroundTint: findMatchTint ?? (onEmphasizedSelection ? nil : modifiedColumnTint),
            accessory: currentAccessory,
            accessoryRole: DataGridCellAccessoryGlyph.Role(
                accessory: currentAccessory,
                isEmphasized: onEmphasizedSelection,
                isDisabled: visualState.isDeleted
            ),
            drawsFocusBorder: isFocusedCell && onEmphasizedSelection && !hasOverlay,
            drawsFocusRing: false
        )
    }

    private func resolvedTextColor() -> NSColor {
        if findMatchTint != nil { return .black }
        return onEmphasizedSelection ? .alternateSelectedControlTextColor : textColor
    }

    private var currentAccessory: DataGridCellAccessory {
        DataGridCellAccessory.visible(
            for: kind,
            isEditable: isEditableCell,
            rawValue: rawValue
        )
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let accessory = currentAccessory
        let accessoryRect = accessory.frame(in: bounds)
        guard !accessoryRect.isEmpty, accessoryRect.contains(point) else {
            if event.clickCount == 2 {
                accessoryDelegate?.dataGridCellDidDoubleClick(row: cellRow, columnIndex: cellColumnIndex)
                return
            }
            super.mouseDown(with: event)
            return
        }
        switch accessory {
        case .foreignKey:
            let openInNewTab = event.modifierFlags.contains(.command)
            accessoryDelegate?.dataGridCellDidClickFKArrow(
                row: cellRow,
                columnIndex: cellColumnIndex,
                openInNewTab: openInNewTab
            )
            return
        case .chevron where !visualState.isDeleted:
            accessoryDelegate?.dataGridCellDidClickChevron(row: cellRow, columnIndex: cellColumnIndex)
            return
        case .none, .chevron:
            super.mouseDown(with: event)
        }
    }

    private func colorsEqual(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (l?, r?): return l == r
        default: return false
        }
    }
}
