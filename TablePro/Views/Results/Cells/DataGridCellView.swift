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
    private var hasOverlay: Bool = false
    private var findMatchTint: NSColor?

    private var cachedLine: CTLine?

    private enum AccessoryRole: Hashable {
        case foreignKeyNormal
        case foreignKeyEmphasized
        case chevronNormal
        case chevronEmphasized
        case chevronDisabled

        var symbolName: String {
            switch self {
            case .foreignKeyNormal, .foreignKeyEmphasized:
                return "arrow.forward"
            case .chevronNormal, .chevronEmphasized, .chevronDisabled:
                return "chevron.up.chevron.down"
            }
        }

        /// The bare arrow spends its whole point size on the arrow itself, where the circled variant
        /// spent most of it on the ring, so 14 here would draw an arrow half again as large as the
        /// one it replaced. 12 keeps the ink at 11 x 9 in the 16 x 16 accessory rect, close to the
        /// dropdown chevron's weight and to the 13pt cell text.
        var pointSize: CGFloat {
            switch self {
            case .foreignKeyNormal, .foreignKeyEmphasized:
                return 12
            case .chevronNormal, .chevronEmphasized, .chevronDisabled:
                return 10
            }
        }

        var color: NSColor {
            switch self {
            case .foreignKeyNormal, .chevronNormal:
                return .secondaryLabelColor
            case .foreignKeyEmphasized, .chevronEmphasized:
                return .alternateSelectedControlTextColor
            case .chevronDisabled:
                return .tertiaryLabelColor
            }
        }
    }

    private struct AccessoryGlyphKey: Hashable {
        let role: AccessoryRole
        let appearance: NSAppearance.Name
        let increasedContrast: Bool
    }

    private struct AccessoryGlyph {
        let image: CGImage
        let pointSize: NSSize
    }

    private static var accessoryGlyphs: [AccessoryGlyphKey: AccessoryGlyph] = [:]

    /// Rasterizing resolves the dynamic symbol color, so a cached bitmap belongs to exactly one
    /// appearance. Keying on the appearance is what keeps a dark window from being served the
    /// light bitmap, and `NSAppearance.currentDrawing()` only reports the cell's own appearance
    /// while AppKit is inside `draw(_:)`, `updateLayer` or `layout`.
    private static func accessoryGlyph(for role: AccessoryRole) -> AccessoryGlyph? {
        let key = AccessoryGlyphKey(
            role: role,
            appearance: NSAppearance.currentDrawing().name,
            increasedContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )
        if let cached = accessoryGlyphs[key] {
            return cached
        }
        guard let glyph = makeAccessoryGlyph(role) else { return nil }
        accessoryGlyphs[key] = glyph
        return glyph
    }

    private static func makeAccessoryGlyph(_ role: AccessoryRole) -> AccessoryGlyph? {
        let config = NSImage.SymbolConfiguration(pointSize: role.pointSize, weight: .regular)
            .applying(.init(hierarchicalColor: role.color))
        guard let image = NSImage(systemSymbolName: role.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return AccessoryGlyph(image: cgImage, pointSize: image.size)
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
            cachedLine = nil
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
            cachedLine = nil
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
        cachedLine = nil
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

    override func draw(_ dirtyRect: NSRect) {
        if let tint = findMatchTint {
            tint.setFill()
            bounds.fill()
        } else if let tint = modifiedColumnTint, !onEmphasizedSelection {
            tint.setFill()
            bounds.fill()
        }

        let accessory = currentAccessory
        let accessoryRect = accessory.frame(in: bounds)

        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        drawText(availableWidth: accessory.availableTextWidth(in: bounds))
        drawAccessory(accessory, in: accessoryRect)
        NSGraphicsContext.current?.restoreGraphicsState()

        if isFocusedCell && onEmphasizedSelection && !hasOverlay {
            drawFocusBorder()
        }
    }

    private func drawText(availableWidth: CGFloat) {
        guard !displayText.isEmpty else { return }
        guard availableWidth > 0 else { return }
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let fullLine = cachedCTLine()
        let typographicWidth = CTLineGetTypographicBounds(fullLine, nil, nil, nil)
        let ellipsisLine = makeEllipsisLine()
        let ellipsisWidth = CTLineGetTypographicBounds(ellipsisLine, nil, nil, nil)
        guard Double(availableWidth) >= ellipsisWidth else { return }

        let lineToDraw: CTLine
        if typographicWidth > Double(availableWidth) {
            lineToDraw = CTLineCreateTruncatedLine(fullLine, Double(availableWidth), .end, ellipsisLine) ?? ellipsisLine
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
        if findMatchTint != nil { return .black }
        return onEmphasizedSelection ? .alternateSelectedControlTextColor : textColor
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

    private var currentAccessory: DataGridCellAccessory {
        DataGridCellAccessory.visible(
            for: kind,
            isEditable: isEditableCell,
            rawValue: rawValue
        )
    }

    private func drawAccessory(_ accessory: DataGridCellAccessory, in rect: NSRect) {
        guard !rect.isEmpty else { return }
        let role: AccessoryRole
        switch accessory {
        case .foreignKey:
            role = onEmphasizedSelection ? .foreignKeyEmphasized : .foreignKeyNormal
        case .chevron:
            if visualState.isDeleted {
                role = .chevronDisabled
            } else if onEmphasizedSelection {
                role = .chevronEmphasized
            } else {
                role = .chevronNormal
            }
        case .none:
            return
        }
        guard let glyph = Self.accessoryGlyph(for: role),
              let context = NSGraphicsContext.current?.cgContext else { return }
        let drawRect = Self.centeredGlyphRect(pointSize: glyph.pointSize, in: rect)
        context.saveGState()
        context.translateBy(x: drawRect.minX, y: drawRect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(glyph.image, in: CGRect(origin: .zero, size: drawRect.size))
        context.restoreGState()
    }

    /// A symbol stretched to fill the accessory rect stops looking like a system symbol, so the
    /// glyph draws at its own point size and the rect only ever clamps it. The clamp is one factor
    /// across both axes, because clamping each axis on its own would distort the glyph exactly the
    /// way filling the rect did. The origin rounds to whole points so a glyph narrower than its rect
    /// by an odd number of points does not land on a half point and blur at 1x.
    private static func centeredGlyphRect(pointSize: NSSize, in rect: NSRect) -> NSRect {
        let scale = min(1, rect.width / pointSize.width, rect.height / pointSize.height)
        let size = NSSize(
            width: pointSize.width * scale,
            height: pointSize.height * scale
        )
        return NSRect(
            x: (rect.midX - size.width / 2).rounded(),
            y: (rect.midY - size.height / 2).rounded(),
            width: size.width,
            height: size.height
        )
    }

    private func drawFocusBorder() {
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        NSColor.alternateSelectedControlTextColor.setStroke()
        path.stroke()
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
