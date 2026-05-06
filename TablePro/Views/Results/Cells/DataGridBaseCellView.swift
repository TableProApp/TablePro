//
//  DataGridBaseCellView.swift
//  TablePro
//

import AppKit
import QuartzCore

class DataGridBaseCellView: NSTableCellView {
    class var reuseIdentifier: NSUserInterfaceItemIdentifier {
        fatalError("subclass must override reuseIdentifier")
    }

    let cellTextField: CellTextField
    weak var accessoryDelegate: DataGridCellAccessoryDelegate?
    var nullDisplayString: String = ""
    var cellRow: Int = -1
    var cellColumnIndex: Int = -1

    private var textFieldTrailingConstraint: NSLayoutConstraint!

    var changeBackgroundColor: NSColor? {
        didSet {
            if let color = changeBackgroundColor {
                backgroundView.layer?.backgroundColor = color.cgColor
                backgroundView.isHidden = (backgroundStyle == .emphasized)
            } else {
                backgroundView.layer?.backgroundColor = nil
                backgroundView.isHidden = true
            }
        }
    }

    var isFocusedCell: Bool = false {
        didSet {
            guard oldValue != isFocusedCell else { return }
            updateFocusPresentation()
        }
    }

    private lazy var focusOverlay: CellFocusOverlay = {
        let overlay = CellFocusOverlay()
        addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        return overlay
    }()

    private(set) lazy var backgroundView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view, positioned: .below, relativeTo: subviews.first)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        view.isHidden = true
        return view
    }()

    override required init(frame frameRect: NSRect) {
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

    private func commonInit() {
        wantsLayer = true
        textField = cellTextField
        addSubview(cellTextField)

        textFieldTrailingConstraint = cellTextField.trailingAnchor.constraint(
            equalTo: trailingAnchor,
            constant: -DataGridMetrics.cellHorizontalInset
        )

        NSLayoutConstraint.activate([
            cellTextField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DataGridMetrics.cellHorizontalInset),
            textFieldTrailingConstraint,
            cellTextField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        installAccessory()
    }

    func configure(content: DataGridCellContent, state: DataGridCellState) {
        cellRow = state.row
        cellColumnIndex = state.columnIndex

        applyContent(content, isLargeDataset: state.isLargeDataset)
        applyVisualState(state)

        cellTextField.isEditable = state.isEditable && !state.visualState.isDeleted

        let newInset = textFieldTrailingInset(for: content, state: state)
        if textFieldTrailingConstraint.constant != newInset {
            textFieldTrailingConstraint.constant = newInset
        }

        updateAccessoryVisibility(content: content, state: state)

        cellTextField.setAccessibilityLabel(content.accessibilityLabel)
        setAccessibilityRowIndexRange(NSRange(location: state.row, length: 1))
        setAccessibilityColumnIndexRange(NSRange(location: state.columnIndex, length: 1))
    }

    func installAccessory() {}

    func updateAccessoryVisibility(content: DataGridCellContent, state: DataGridCellState) {}

    func textFieldTrailingInset(for content: DataGridCellContent, state: DataGridCellState) -> CGFloat {
        -4
    }

    private func applyContent(_ content: DataGridCellContent, isLargeDataset: Bool) {
        cellTextField.placeholderString = nil

        switch content.placeholder {
        case .none:
            cellTextField.stringValue = content.displayText
            cellTextField.originalValue = content.rawValue
            cellTextField.font = ThemeEngine.shared.dataGridFonts.regular
            cellTextField.tag = DataGridFontVariant.regular
            cellTextField.textColor = .labelColor

        case .null:
            cellTextField.stringValue = ""
            cellTextField.originalValue = nil
            cellTextField.font = ThemeEngine.shared.dataGridFonts.italic
            cellTextField.tag = DataGridFontVariant.italic
            cellTextField.textColor = .secondaryLabelColor
            if !isLargeDataset {
                cellTextField.placeholderString = nullDisplayString
            }

        case .empty:
            cellTextField.stringValue = ""
            cellTextField.originalValue = nil
            cellTextField.font = ThemeEngine.shared.dataGridFonts.italic
            cellTextField.tag = DataGridFontVariant.italic
            cellTextField.textColor = .secondaryLabelColor
            if !isLargeDataset {
                cellTextField.placeholderString = String(localized: "Empty")
            }

        case .defaultMarker:
            cellTextField.stringValue = ""
            cellTextField.originalValue = nil
            cellTextField.font = ThemeEngine.shared.dataGridFonts.medium
            cellTextField.tag = DataGridFontVariant.medium
            cellTextField.textColor = .systemBlue
            if !isLargeDataset {
                cellTextField.placeholderString = String(localized: "DEFAULT")
            }
        }
    }

    private func applyVisualState(_ state: DataGridCellState) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if state.visualState.isDeleted {
            changeBackgroundColor = ThemeEngine.shared.colors.dataGrid.deleted
        } else if state.visualState.isInserted {
            changeBackgroundColor = ThemeEngine.shared.colors.dataGrid.inserted
        } else if state.visualState.modifiedColumns.contains(state.columnIndex) {
            changeBackgroundColor = ThemeEngine.shared.colors.dataGrid.modified
        } else {
            changeBackgroundColor = nil
        }

        isFocusedCell = state.isFocused

        CATransaction.commit()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            backgroundView.isHidden = (backgroundStyle == .emphasized) || (changeBackgroundColor == nil)
            updateFocusPresentation()
        }
    }

    override var focusRingMaskBounds: NSRect {
        backgroundStyle == .emphasized ? .zero : bounds
    }

    override func drawFocusRingMask() {
        guard backgroundStyle != .emphasized else { return }
        NSBezierPath(rect: bounds).fill()
    }

    private func updateFocusPresentation() {
        let onEmphasized = backgroundStyle == .emphasized
        focusOverlay.style = (isFocusedCell && onEmphasized) ? .contrastingBorder : .hidden
        focusRingType = (isFocusedCell && !onEmphasized) ? .exterior : .none
        noteFocusRingMaskChanged()
    }
}
