//
//  DataGridCellView.swift
//  TablePro
//

import AppKit
import CoreText

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

    private var cachedLine: CTLine?

    private var accessoryHitRect: NSRect = .zero

    private static let chevronNormal = makeAccessoryCGImage("chevron.up.chevron.down", pointSize: 10, color: .secondaryLabelColor)
    private static let chevronEmphasized = makeAccessoryCGImage("chevron.up.chevron.down", pointSize: 10, color: .alternateSelectedControlTextColor)
    private static let chevronDisabled = makeAccessoryCGImage("chevron.up.chevron.down", pointSize: 10, color: .tertiaryLabelColor)
    private static let fkArrowNormal = makeAccessoryCGImage("arrow.right.circle.fill", pointSize: 14, color: .secondaryLabelColor)
    private static let fkArrowEmphasized = makeAccessoryCGImage("arrow.right.circle.fill", pointSize: 14, color: .alternateSelectedControlTextColor)

    private static func makeAccessoryCGImage(_ name: String, pointSize: CGFloat, color: NSColor) -> CGImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(.init(hierarchicalColor: color))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

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

        let nextDisplayText: String
        let nextFont: NSFont
        let nextColor: NSColor
        let deletedTextColor = state.visualState.isDeleted ? palette.deletedRowText : nil

        switch content.placeholder {
        case .none:
            nextDisplayText = content.displayText
            nextFont = palette.regularFont
            nextColor = deletedTextColor ?? .labelColor
        case .null:
            nextDisplayText = state.isLargeDataset ? "" : nullDisplayString
            nextFont = palette.italicFont
            nextColor = deletedTextColor ?? .secondaryLabelColor
        case .empty:
            nextDisplayText = state.isLargeDataset ? "" : String(localized: "Empty")
            nextFont = palette.italicFont
            nextColor = deletedTextColor ?? .secondaryLabelColor
        case .defaultMarker:
            nextDisplayText = state.isLargeDataset ? "" : String(localized: "DEFAULT")
            nextFont = palette.mediumFont
            nextColor = deletedTextColor ?? .systemBlue
        }

        if displayText != nextDisplayText
            || textFont != nextFont
            || textColor != nextColor {
            displayText = nextDisplayText
            textFont = nextFont
            textColor = nextColor
            cachedLine = nil
            needsRedraw = true
        }

        if rawValue != content.rawValue {
            rawValue = content.rawValue
            needsRedraw = true
        }
        placeholder = content.placeholder
        isLargeDataset = state.isLargeDataset
        isEditableCell = state.isEditable

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

    override func accessibilityLabel() -> String? {
        let value = rawValue ?? String(localized: "NULL")
        return String(
            format: String(localized: "Row %d, column %d: %@"),
            cellRow + 1,
            cellColumnIndex + 1,
            value
        )
    }

    func applyEmphasizedSelection(_ value: Bool) {
        guard onEmphasizedSelection != value else { return }
        onEmphasizedSelection = value
        cachedLine = nil
        updateFocusPresentation()
    }

    private func updateFocusPresentation() {
        focusRingType = (isFocusedCell && !onEmphasizedSelection) ? .exterior : .none
        noteFocusRingMaskChanged()
        needsDisplay = true
    }

    override var focusRingMaskBounds: NSRect {
        onEmphasizedSelection ? .zero : bounds
    }

    override func drawFocusRingMask() {
        guard !onEmphasizedSelection else { return }
        NSBezierPath(rect: bounds).fill()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if let tint = modifiedColumnTint, !onEmphasizedSelection {
            tint.setFill()
            bounds.fill()
        }

        let accessoryRect = computeAccessoryRect()
        accessoryHitRect = accessoryRect

        drawText(reservingTrailingWidth: accessoryRect.width)
        drawAccessory(in: accessoryRect)

        if isFocusedCell && onEmphasizedSelection {
            drawFocusBorder()
        }
    }

    private func drawText(reservingTrailingWidth trailing: CGFloat) {
        guard !displayText.isEmpty else { return }
        let availableWidth = bounds.width - 2 * DataGridMetrics.cellHorizontalInset - trailing
        guard availableWidth > 0 else { return }
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let fullLine = cachedCTLine()
        let lineToDraw: CTLine
        let typographicWidth = CTLineGetTypographicBounds(fullLine, nil, nil, nil)
        if typographicWidth > Double(availableWidth) {
            let ellipsis = makeEllipsisLine()
            lineToDraw = CTLineCreateTruncatedLine(fullLine, Double(availableWidth), .end, ellipsis) ?? fullLine
        } else {
            lineToDraw = fullLine
        }

        let baselineY = (bounds.height - textFont.ascender + textFont.descender - textFont.leading) / 2 + textFont.ascender

        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: DataGridMetrics.cellHorizontalInset, y: baselineY)
        CTLineDraw(lineToDraw, context)
        context.restoreGState()
    }

    private func resolvedTextColor() -> NSColor {
        onEmphasizedSelection ? .alternateSelectedControlTextColor : textColor
    }

    private func cachedCTLine() -> CTLine {
        if let cached = cachedLine { return cached }
        let textNS = displayText as NSString
        let truncated: String
        if textNS.length > 300 {
            truncated = textNS.substring(to: 300) + "\u{2026}"
        } else {
            truncated = displayText
        }
        let attr = NSAttributedString(
            string: truncated,
            attributes: [
                .font: textFont,
                .foregroundColor: resolvedTextColor()
            ]
        )
        let line = CTLineCreateWithAttributedString(attr as CFAttributedString)
        cachedLine = line
        return line
    }

    private func makeEllipsisLine() -> CTLine {
        let attr = NSAttributedString(
            string: "\u{2026}",
            attributes: [
                .font: textFont,
                .foregroundColor: resolvedTextColor()
            ]
        )
        return CTLineCreateWithAttributedString(attr as CFAttributedString)
    }

    private func computeAccessoryRect() -> NSRect {
        switch kind {
        case .text:
            return .zero
        case .foreignKey:
            guard let raw = rawValue, !raw.isEmpty else { return .zero }
            let size = NSSize(width: 16, height: 16)
            let x = bounds.maxX - DataGridMetrics.cellHorizontalInset - size.width
            let y = (bounds.height - size.height) / 2
            return NSRect(x: x, y: y, width: size.width, height: size.height)
        case .dropdown, .boolean, .date, .json, .blob:
            guard isEditableCell else { return .zero }
            let size = NSSize(width: 12, height: 14)
            let x = bounds.maxX - DataGridMetrics.cellHorizontalInset - size.width
            let y = (bounds.height - size.height) / 2
            return NSRect(x: x, y: y, width: size.width, height: size.height)
        }
    }

    private func drawAccessory(in rect: NSRect) {
        guard !rect.isEmpty else { return }
        let image: CGImage?
        switch kind {
        case .text:
            return
        case .foreignKey:
            image = onEmphasizedSelection ? Self.fkArrowEmphasized : Self.fkArrowNormal
        case .dropdown, .boolean, .date, .json, .blob:
            if visualState.isDeleted {
                image = Self.chevronDisabled
            } else if onEmphasizedSelection {
                image = Self.chevronEmphasized
            } else {
                image = Self.chevronNormal
            }
        }
        guard let cgImage = image, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(cgImage, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    private func drawFocusBorder() {
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        NSColor.alternateSelectedControlTextColor.setStroke()
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !accessoryHitRect.isEmpty && accessoryHitRect.contains(point) {
            switch kind {
            case .foreignKey:
                accessoryDelegate?.dataGridCellDidClickFKArrow(row: cellRow, columnIndex: cellColumnIndex)
                return
            case .dropdown, .boolean, .date, .json, .blob:
                guard !visualState.isDeleted else {
                    super.mouseDown(with: event)
                    return
                }
                accessoryDelegate?.dataGridCellDidClickChevron(row: cellRow, columnIndex: cellColumnIndex)
                return
            case .text:
                break
            }
        }
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        var view: NSView? = self
        while let parent = view?.superview {
            if let rowView = parent as? DataGridRowView,
               let menu = rowView.menu(for: event) {
                NSMenu.popUpContextMenu(menu, with: event, for: self)
                return
            }
            view = parent
        }
        super.rightMouseDown(with: event)
    }

    private func colorsEqual(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (l?, r?): return l == r
        default: return false
        }
    }
}
