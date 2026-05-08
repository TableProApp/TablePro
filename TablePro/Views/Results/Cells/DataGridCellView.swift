//
//  DataGridCellView.swift
//  TablePro
//

import AppKit

@MainActor
final class DataGridCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("dataCell")

    let cellTextField: CellTextField
    weak var accessoryDelegate: DataGridCellAccessoryDelegate?
    var nullDisplayString: String = ""

    var kind: DataGridCellKind = .text
    private(set) var cellRow: Int = -1
    private(set) var cellColumnIndex: Int = -1

    private var modifiedColumnTint: NSColor?
    private var deletedRowTextColor: NSColor?
    private var accessoryVisible: Bool = false
    private var isFocusedCell: Bool = false
    private var onEmphasizedSelection: Bool = false

    private var textFieldTrailingConstraint: NSLayoutConstraint!

    private static let fkSymbol = makeSymbol(
        name: "arrow.right.circle.fill",
        size: NSSize(width: 16, height: 16),
        accessibilityDescription: String(localized: "Navigate to referenced row")
    )
    private static let chevronSymbol = makeSymbol(
        name: "chevron.up.chevron.down",
        size: NSSize(width: 10, height: 12),
        accessibilityDescription: String(localized: "Open editor")
    )

    private lazy var accessoryAccessibilityElement: AccessoryAccessibilityElement = {
        let element = AccessoryAccessibilityElement(owner: self)
        return element
    }()

    override init(frame frameRect: NSRect) {
        cellTextField = Self.makeTextField()
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        cellTextField = Self.makeTextField()
        super.init(coder: coder)
        commonInit()
    }

    private static func makeTextField() -> CellTextField {
        let field = CellTextField()
        field.font = ThemeEngine.shared.dataGridFonts.regular
        field.drawsBackground = false
        field.isBordered = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.truncatesLastVisibleLine = true
        field.cell?.usesSingleLineMode = true
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    private static func makeSymbol(
        name: String,
        size: NSSize,
        accessibilityDescription: String
    ) -> NSImage {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription) else {
            return NSImage(size: size)
        }
        image.size = size
        image.isTemplate = true
        return image
    }

    private func commonInit() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        canDrawSubviewsIntoLayer = true

        addSubview(cellTextField)
        textFieldTrailingConstraint = cellTextField.trailingAnchor.constraint(
            equalTo: trailingAnchor,
            constant: -DataGridMetrics.cellHorizontalInset
        )
        NSLayoutConstraint.activate([
            cellTextField.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: DataGridMetrics.cellHorizontalInset
            ),
            textFieldTrailingConstraint,
            cellTextField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
    }

    override var allowsVibrancy: Bool { false }

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
        state: DataGridCellState
    ) {
        self.kind = kind
        cellRow = state.row
        cellColumnIndex = state.columnIndex

        applyContent(content, isLargeDataset: state.isLargeDataset, visualState: state.visualState)
        applyVisualState(state)

        cellTextField.isEditable = state.isEditable && !state.visualState.isDeleted

        let newAccessoryVisible = computeAccessoryVisibility(content: content, state: state)
        let newInset = trailingInset(for: newAccessoryVisible)
        if textFieldTrailingConstraint.constant != newInset {
            textFieldTrailingConstraint.constant = newInset
        }
        if newAccessoryVisible != accessoryVisible {
            accessoryVisible = newAccessoryVisible
            needsDisplay = true
        }

        cellTextField.setAccessibilityLabel(content.accessibilityLabel)
        setAccessibilityRowIndexRange(NSRange(location: state.row, length: 1))
        setAccessibilityColumnIndexRange(NSRange(location: state.columnIndex, length: 1))
        updateAccessoryAccessibility()
    }

    private func applyContent(
        _ content: DataGridCellContent,
        isLargeDataset: Bool,
        visualState: RowVisualState
    ) {
        cellTextField.placeholderString = nil
        deletedRowTextColor = visualState.isDeleted
            ? ThemeEngine.shared.colors.dataGrid.deletedText
            : nil

        switch content.placeholder {
        case .none:
            cellTextField.stringValue = content.displayText
            cellTextField.originalValue = content.rawValue
            cellTextField.font = ThemeEngine.shared.dataGridFonts.regular
            cellTextField.tag = DataGridFontVariant.regular
            cellTextField.textColor = deletedRowTextColor ?? .labelColor

        case .null:
            cellTextField.stringValue = ""
            cellTextField.originalValue = nil
            cellTextField.font = ThemeEngine.shared.dataGridFonts.italic
            cellTextField.tag = DataGridFontVariant.italic
            cellTextField.textColor = deletedRowTextColor ?? .secondaryLabelColor
            if !isLargeDataset {
                cellTextField.placeholderString = nullDisplayString
            }

        case .empty:
            cellTextField.stringValue = ""
            cellTextField.originalValue = nil
            cellTextField.font = ThemeEngine.shared.dataGridFonts.italic
            cellTextField.tag = DataGridFontVariant.italic
            cellTextField.textColor = deletedRowTextColor ?? .secondaryLabelColor
            if !isLargeDataset {
                cellTextField.placeholderString = String(localized: "Empty")
            }

        case .defaultMarker:
            cellTextField.stringValue = ""
            cellTextField.originalValue = nil
            cellTextField.font = ThemeEngine.shared.dataGridFonts.medium
            cellTextField.tag = DataGridFontVariant.medium
            cellTextField.textColor = deletedRowTextColor ?? .systemBlue
            if !isLargeDataset {
                cellTextField.placeholderString = String(localized: "DEFAULT")
            }
        }
    }

    private func applyVisualState(_ state: DataGridCellState) {
        let nextTint: NSColor?
        if state.visualState.isDeleted || state.visualState.isInserted {
            nextTint = nil
        } else if state.visualState.modifiedColumns.contains(state.columnIndex) {
            nextTint = ThemeEngine.shared.colors.dataGrid.modified
        } else {
            nextTint = nil
        }

        if !colorsEqual(modifiedColumnTint, nextTint) {
            modifiedColumnTint = nextTint
            needsDisplay = true
        }

        if isFocusedCell != state.isFocused {
            isFocusedCell = state.isFocused
            updateFocusPresentation()
        }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let nextEmphasized = backgroundStyle == .emphasized
            guard nextEmphasized != onEmphasizedSelection else { return }
            onEmphasizedSelection = nextEmphasized
            needsDisplay = true
            updateFocusPresentation()
        }
    }

    private func updateFocusPresentation() {
        focusRingType = (isFocusedCell && !onEmphasizedSelection) ? .exterior : .none
        noteFocusRingMaskChanged()
    }

    override var focusRingMaskBounds: NSRect {
        onEmphasizedSelection ? .zero : bounds
    }

    override func drawFocusRingMask() {
        guard !onEmphasizedSelection else { return }
        NSBezierPath(rect: bounds).fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        if let tint = modifiedColumnTint, !onEmphasizedSelection {
            tint.setFill()
            bounds.fill()
        }
        drawAccessoryIfNeeded()
    }

    private func drawAccessoryIfNeeded() {
        guard accessoryVisible, let image = accessoryImage() else { return }
        let rect = accessoryRect()
        guard !rect.isEmpty else { return }
        let tintColor: NSColor = onEmphasizedSelection ? .alternateSelectedControlTextColor : .tertiaryLabelColor
        let configuration = NSImage.SymbolConfiguration(paletteColors: [tintColor])
        let tinted = image.withSymbolConfiguration(configuration) ?? image
        tinted.draw(in: rect)
    }

    private func accessoryImage() -> NSImage? {
        switch kind {
        case .foreignKey: return Self.fkSymbol
        case .text: return nil
        case .dropdown, .boolean, .date, .json, .blob: return Self.chevronSymbol
        }
    }

    private func accessoryRect() -> NSRect {
        let size: NSSize
        switch kind {
        case .foreignKey: size = NSSize(width: 16, height: 16)
        case .text: return .zero
        case .dropdown, .boolean, .date, .json, .blob: size = NSSize(width: 10, height: 12)
        }
        let x = bounds.maxX - DataGridMetrics.cellHorizontalInset - size.width
        let y = (bounds.height - size.height) / 2
        return NSRect(x: x, y: y, width: size.width, height: size.height).integral
    }

    private func trailingInset(for accessoryVisible: Bool) -> CGFloat {
        guard accessoryVisible else { return -DataGridMetrics.cellHorizontalInset }
        switch kind {
        case .foreignKey: return -22
        case .text: return -DataGridMetrics.cellHorizontalInset
        case .dropdown, .boolean, .date, .json, .blob: return -18
        }
    }

    private func computeAccessoryVisibility(
        content: DataGridCellContent,
        state: DataGridCellState
    ) -> Bool {
        switch kind {
        case .foreignKey:
            guard let raw = content.rawValue, !raw.isEmpty else { return false }
            return true
        case .text:
            return false
        case .dropdown, .boolean, .date, .json, .blob:
            return state.isEditable && !state.visualState.isDeleted
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard accessoryVisible else {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard accessoryRect().insetBy(dx: -2, dy: -2).contains(point) else {
            super.mouseDown(with: event)
            return
        }
        invokeAccessory()
    }

    private func invokeAccessory() {
        switch kind {
        case .foreignKey:
            accessoryDelegate?.dataGridCellDidClickFKArrow(row: cellRow, columnIndex: cellColumnIndex)
        case .text:
            return
        case .dropdown, .boolean, .date, .json, .blob:
            accessoryDelegate?.dataGridCellDidClickChevron(row: cellRow, columnIndex: cellColumnIndex)
        }
    }

    override func accessibilityChildren() -> [Any]? {
        var children: [Any] = [cellTextField]
        if accessoryVisible {
            children.append(accessoryAccessibilityElement)
        }
        return children
    }

    private func updateAccessoryAccessibility() {
        guard accessoryVisible else { return }
        let label: String
        switch kind {
        case .foreignKey: label = String(localized: "Navigate to referenced row")
        case .text: return
        case .dropdown, .boolean, .date, .json, .blob: label = String(localized: "Open editor")
        }
        accessoryAccessibilityElement.update(label: label)
    }

    private func colorsEqual(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (l?, r?): return l == r
        default: return false
        }
    }
}

@MainActor
private final class AccessoryAccessibilityElement: NSAccessibilityElement {
    weak var owner: DataGridCellView?

    init(owner: DataGridCellView) {
        super.init()
        self.owner = owner
        setAccessibilityRole(.button)
        setAccessibilityParent(owner)
    }

    func update(label: String) {
        setAccessibilityLabel(label)
    }

    override func accessibilityFrame() -> NSRect {
        guard let owner, let window = owner.window else { return .zero }
        let inOwner = ownerAccessoryRect()
        let inWindow = owner.convert(inOwner, to: nil)
        return window.convertToScreen(inWindow)
    }

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        guard let owner else { return false }
        switch owner.kind {
        case .foreignKey:
            owner.accessoryDelegate?.dataGridCellDidClickFKArrow(
                row: owner.cellRow,
                columnIndex: owner.cellColumnIndex
            )
        case .text:
            return false
        case .dropdown, .boolean, .date, .json, .blob:
            owner.accessoryDelegate?.dataGridCellDidClickChevron(
                row: owner.cellRow,
                columnIndex: owner.cellColumnIndex
            )
        }
        return true
    }

    private func ownerAccessoryRect() -> NSRect {
        guard let owner else { return .zero }
        let size: NSSize
        switch owner.kind {
        case .foreignKey: size = NSSize(width: 16, height: 16)
        case .text: return .zero
        case .dropdown, .boolean, .date, .json, .blob: size = NSSize(width: 10, height: 12)
        }
        let x = owner.bounds.maxX - DataGridMetrics.cellHorizontalInset - size.width
        let y = (owner.bounds.height - size.height) / 2
        return NSRect(x: x, y: y, width: size.width, height: size.height).integral
    }
}
