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

    private var textFont: NSFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    private var textColor: NSColor = .labelColor
    private var modifiedColumnTint: NSColor?

    private var visualState: RowVisualState = .empty
    private var isFocusedCell: Bool = false
    private var onEmphasizedSelection: Bool = false

    private var attributedCache: NSAttributedString?

    private var accessoryHitRect: NSRect = .zero

    private static let chevronNormal = makeAccessoryImage("chevron.up.chevron.down", pointSize: 10, color: .secondaryLabelColor)
    private static let chevronEmphasized = makeAccessoryImage("chevron.up.chevron.down", pointSize: 10, color: .alternateSelectedControlTextColor)
    private static let chevronDisabled = makeAccessoryImage("chevron.up.chevron.down", pointSize: 10, color: .tertiaryLabelColor)
    private static let fkArrowNormal = makeAccessoryImage("arrow.right.circle.fill", pointSize: 14, color: .secondaryLabelColor)
    private static let fkArrowEmphasized = makeAccessoryImage("arrow.right.circle.fill", pointSize: 14, color: .alternateSelectedControlTextColor)

    private static func makeAccessoryImage(_ name: String, pointSize: CGFloat, color: NSColor) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(.init(hierarchicalColor: color))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage()
    }

    private static let placeholderParagraph: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        return p
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        canDrawSubviewsIntoLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
    }

    override var allowsVibrancy: Bool { false }
    override var isFlipped: Bool { true }

    override func makeBackingLayer() -> CALayer {
        let layer = super.makeBackingLayer()
        layer.actions = Self.disabledLayerActions
        return layer
    }

    private static let disabledLayerActions: [String: any CAAction] = [
        "position": NSNull(),
        "bounds": NSNull(),
        "frame": NSNull(),
        "contents": NSNull(),
        "hidden": NSNull(),
    ]

    func configure(
        kind: DataGridCellKind,
        content: DataGridCellContent,
        state: DataGridCellState,
        palette: DataGridCellPalette
    ) {
        self.kind = kind
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
            attributedCache = nil
        }

        rawValue = content.rawValue
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
        }

        visualState = state.visualState
        if isFocusedCell != state.isFocused {
            isFocusedCell = state.isFocused
            updateFocusPresentation()
        }

        setAccessibilityLabel(content.accessibilityLabel)
        setAccessibilityRowIndexRange(NSRange(location: state.row, length: 1))
        setAccessibilityColumnIndexRange(NSRange(location: state.columnIndex, length: 1))

        needsDisplay = true
    }

    private func currentEmphasizedSelection() -> Bool {
        var view: NSView? = superview
        while let candidate = view {
            if let row = candidate as? NSTableRowView {
                return row.isSelected && row.isEmphasized
            }
            view = candidate.superview
        }
        return false
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        let nextEmphasized = currentEmphasizedSelection()
        guard nextEmphasized != onEmphasizedSelection else { return }
        onEmphasizedSelection = nextEmphasized
        attributedCache = nil
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
        let attr = cachedAttributedString()
        var rect = bounds.insetBy(dx: DataGridMetrics.cellHorizontalInset, dy: 0)
        rect.size.width -= trailing
        guard rect.width > 0 else { return }
        let lineHeight = textFont.ascender - textFont.descender + textFont.leading
        rect.origin.y = max(0, (bounds.height - lineHeight) / 2)
        rect.size.height = lineHeight + 2
        attr.draw(with: rect, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin], context: nil)
    }

    private func resolvedTextColor() -> NSColor {
        onEmphasizedSelection ? .alternateSelectedControlTextColor : textColor
    }

    private func cachedAttributedString() -> NSAttributedString {
        if let cached = attributedCache { return cached }
        let textNS = displayText as NSString
        let truncated: String
        if textNS.length > 300 {
            truncated = textNS.substring(to: 300) + "\u{2026}"
        } else {
            truncated = displayText
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: textFont,
            .foregroundColor: resolvedTextColor(),
            .paragraphStyle: Self.placeholderParagraph
        ]
        let str = NSAttributedString(string: truncated, attributes: attrs)
        attributedCache = str
        return str
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
        let image: NSImage
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
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
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
