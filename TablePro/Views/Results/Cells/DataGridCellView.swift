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
    private var accessoryWidthConstraint: NSLayoutConstraint!
    private var accessoryHeightConstraint: NSLayoutConstraint!

    private static let fkSymbol = makeSymbol(
        name: "arrow.right.circle.fill",
        accessibilityDescription: String(localized: "Navigate to referenced row")
    )
    private static let chevronSymbol = makeSymbol(
        name: "chevron.up.chevron.down",
        accessibilityDescription: String(localized: "Open editor")
    )

    private lazy var accessoryButton: NSButton = {
        let button = NSButton()
        button.bezelStyle = .inline
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.translatesAutoresizingMaskIntoConstraints = false
        button.target = self
        button.action = #selector(handleAccessoryClick(_:))
        button.isHidden = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(button)

        accessoryWidthConstraint = button.widthAnchor.constraint(equalToConstant: 0)
        accessoryHeightConstraint = button.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -DataGridMetrics.cellHorizontalInset
            ),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            accessoryWidthConstraint,
            accessoryHeightConstraint,
        ])
        return button
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

    private static func makeSymbol(name: String, accessibilityDescription: String) -> NSImage {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription) else {
            return NSImage()
        }
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
        state: DataGridCellState,
        palette: DataGridCellPalette
    ) {
        self.kind = kind
        cellRow = state.row
        cellColumnIndex = state.columnIndex

        applyContent(content, isLargeDataset: state.isLargeDataset, visualState: state.visualState, palette: palette)
        applyVisualState(state, palette: palette)

        cellTextField.isEditable = state.isEditable && !state.visualState.isDeleted

        let newAccessoryVisible = computeAccessoryVisibility(content: content, state: state)
        let newInset = trailingInset(for: newAccessoryVisible)
        if textFieldTrailingConstraint.constant != newInset {
            textFieldTrailingConstraint.constant = newInset
        }
        if newAccessoryVisible != accessoryVisible {
            accessoryVisible = newAccessoryVisible
        }
        configureAccessoryButton()

        cellTextField.setAccessibilityLabel(content.accessibilityLabel)
        setAccessibilityRowIndexRange(NSRange(location: state.row, length: 1))
        setAccessibilityColumnIndexRange(NSRange(location: state.columnIndex, length: 1))
    }

    private func applyContent(
        _ content: DataGridCellContent,
        isLargeDataset: Bool,
        visualState: RowVisualState,
        palette: DataGridCellPalette
    ) {
        cellTextField.placeholderString = nil
        deletedRowTextColor = visualState.isDeleted ? palette.deletedRowText : nil

        switch content.placeholder {
        case .none:
            cellTextField.stringValue = content.displayText
            cellTextField.originalValue = content.rawValue
            cellTextField.font = palette.regularFont
            cellTextField.tag = DataGridFontVariant.regular
            cellTextField.textColor = deletedRowTextColor ?? .labelColor

        case .null:
            cellTextField.stringValue = ""
            cellTextField.originalValue = nil
            cellTextField.font = palette.italicFont
            cellTextField.tag = DataGridFontVariant.italic
            cellTextField.textColor = deletedRowTextColor ?? .secondaryLabelColor
            if !isLargeDataset {
                cellTextField.placeholderString = nullDisplayString
            }

        case .empty:
            cellTextField.stringValue = ""
            cellTextField.originalValue = nil
            cellTextField.font = palette.italicFont
            cellTextField.tag = DataGridFontVariant.italic
            cellTextField.textColor = deletedRowTextColor ?? .secondaryLabelColor
            if !isLargeDataset {
                cellTextField.placeholderString = String(localized: "Empty")
            }

        case .defaultMarker:
            cellTextField.stringValue = ""
            cellTextField.originalValue = nil
            cellTextField.font = palette.mediumFont
            cellTextField.tag = DataGridFontVariant.medium
            cellTextField.textColor = deletedRowTextColor ?? .systemBlue
            if !isLargeDataset {
                cellTextField.placeholderString = String(localized: "DEFAULT")
            }
        }
    }

    private func applyVisualState(_ state: DataGridCellState, palette: DataGridCellPalette) {
        let nextTint: NSColor?
        if state.visualState.isDeleted || state.visualState.isInserted {
            nextTint = nil
        } else if state.visualState.modifiedColumns.contains(state.columnIndex) {
            nextTint = palette.modifiedColumnTint
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
            updateAccessoryTint()
        }
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

    override func draw(_ dirtyRect: NSRect) {
        if let tint = modifiedColumnTint, !onEmphasizedSelection {
            tint.setFill()
            bounds.fill()
        }
        drawFocusBorderIfNeeded()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    private func drawFocusBorderIfNeeded() {
        guard isFocusedCell, onEmphasizedSelection else { return }
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        NSColor.alternateSelectedControlTextColor.setStroke()
        path.stroke()
    }

    private func configureAccessoryButton() {
        guard accessoryVisible else {
            if !accessoryButton.isHidden {
                accessoryButton.isHidden = true
            }
            return
        }
        let (image, size, label) = accessoryAssets()
        accessoryButton.image = image
        accessoryButton.setAccessibilityLabel(label)
        accessoryWidthConstraint.constant = size.width
        accessoryHeightConstraint.constant = size.height
        accessoryButton.isHidden = false
        updateAccessoryTint()
    }

    private func accessoryAssets() -> (NSImage, NSSize, String) {
        switch kind {
        case .foreignKey:
            return (
                Self.fkSymbol,
                NSSize(width: 16, height: 16),
                String(localized: "Navigate to referenced row")
            )
        case .text:
            return (NSImage(), .zero, "")
        case .dropdown, .boolean, .date, .json, .blob:
            return (
                Self.chevronSymbol,
                NSSize(width: 12, height: 14),
                String(localized: "Open editor")
            )
        }
    }

    private func updateAccessoryTint() {
        accessoryButton.contentTintColor = onEmphasizedSelection
            ? .alternateSelectedControlTextColor
            : .secondaryLabelColor
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

    @objc private func handleAccessoryClick(_ sender: NSButton) {
        switch kind {
        case .foreignKey:
            accessoryDelegate?.dataGridCellDidClickFKArrow(row: cellRow, columnIndex: cellColumnIndex)
        case .text:
            return
        case .dropdown, .boolean, .date, .json, .blob:
            accessoryDelegate?.dataGridCellDidClickChevron(row: cellRow, columnIndex: cellColumnIndex)
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
