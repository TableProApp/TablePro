//
//  DataGridCellFactory.swift
//  TablePro
//
//  Factory for creating and configuring data grid cells.
//  Extracted from DataGridView coordinator for better maintainability.
//

import AppKit
import QuartzCore

/// Custom button that stores FK row/column context for the click handler
@MainActor
final class FKArrowButton: NSButton {
    var fkRow: Int = 0
    var fkColumnIndex: Int = 0
}

/// Custom button that stores cell row/column context for the chevron click handler
@MainActor
final class CellChevronButton: NSButton {
    var cellRow: Int = -1
    var cellColumnIndex: Int = -1
}

@MainActor
final class DataGridCellFactory {
    private let cellIdentifier = NSUserInterfaceItemIdentifier("DataCell")
    private let rowNumberCellIdentifier = NSUserInterfaceItemIdentifier("RowNumberCell")
    private let largeDatasetThreshold = 5_000

    private var nullDisplayString: String = AppSettingsManager.shared.dataGrid.nullDisplay
    private var settingsObserver: NSObjectProtocol?

    init() {
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .dataGridSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.nullDisplayString = AppSettingsManager.shared.dataGrid.nullDisplay
            }
        }
    }

    deinit {
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Row Number Cell

    func makeRowNumberCell(
        tableView: NSTableView,
        row: Int,
        cachedRowCount: Int,
        visualState: RowVisualState
    ) -> NSView {
        let cellViewId = NSUserInterfaceItemIdentifier("RowNumberCellView")
        let cellView: NSTableCellView
        let cell: NSTextField

        if let reused = tableView.makeView(withIdentifier: cellViewId, owner: nil) as? NSTableCellView,
           let textField = reused.textField {
            cellView = reused
            cell = textField
            cell.font = ThemeEngine.shared.dataGridFonts.rowNumber
        } else {
            cellView = NSTableCellView()
            cellView.identifier = cellViewId

            cell = NSTextField(labelWithString: "")
            cell.alignment = .right
            cell.font = ThemeEngine.shared.dataGridFonts.rowNumber
            cell.tag = DataGridFontVariant.rowNumber
            cell.textColor = .secondaryLabelColor
            cell.translatesAutoresizingMaskIntoConstraints = false

            cellView.textField = cell
            cellView.addSubview(cell)

            NSLayoutConstraint.activate([
                cell.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 4),
                cell.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -4),
                cell.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
            ])
        }

        guard row >= 0 && row < cachedRowCount else {
            cell.stringValue = ""
            return cellView
        }

        cell.stringValue = "\(row + 1)"
        cell.textColor = visualState.isDeleted ? ThemeEngine.shared.colors.dataGrid.deletedText : .secondaryLabelColor
        cellView.setAccessibilityLabel(String(format: String(localized: "Row %d"), row + 1))
        cellView.setAccessibilityRowIndexRange(NSRange(location: row, length: 1))

        return cellView
    }

    // MARK: - Data Cell

    func makeDataCell(
        tableView: NSTableView,
        row: Int,
        columnIndex: Int,
        displayValue: String?,
        rawValue: String?,
        visualState: RowVisualState,
        isEditable: Bool,
        isLargeDataset: Bool,
        isFocused: Bool,
        isDropdown: Bool = false,
        isFKColumn: Bool = false,
        fkArrowTarget: AnyObject? = nil,
        fkArrowAction: Selector? = nil,
        chevronTarget: AnyObject? = nil,
        chevronAction: Selector? = nil,
        delegate: NSTextFieldDelegate
    ) -> NSView {
        let gridCellView: DataGridCellView
        let cell: NSTextField

        if let reused = tableView.makeView(withIdentifier: cellIdentifier, owner: nil) as? DataGridCellView,
           let textField = reused.textField {
            gridCellView = reused
            cell = textField
        } else {
            gridCellView = DataGridCellView()
            gridCellView.identifier = cellIdentifier
            gridCellView.wantsLayer = true

            cell = CellTextField()
            cell.font = ThemeEngine.shared.dataGridFonts.regular
            cell.drawsBackground = false
            cell.isBordered = false
            cell.focusRingType = .none
            cell.lineBreakMode = .byTruncatingTail
            cell.maximumNumberOfLines = 1
            cell.cell?.truncatesLastVisibleLine = true
            cell.cell?.usesSingleLineMode = true
            cell.translatesAutoresizingMaskIntoConstraints = false

            gridCellView.textField = cell
            gridCellView.addSubview(cell)

            let fkButton = createFKArrowButton()
            gridCellView.addSubview(fkButton)
            gridCellView.fkArrowButton = fkButton

            let chevron = createChevronButton()
            gridCellView.addSubview(chevron)
            gridCellView.chevronButton = chevron

            let trailing = cell.trailingAnchor.constraint(equalTo: gridCellView.trailingAnchor, constant: -4)
            gridCellView.textFieldTrailing = trailing

            NSLayoutConstraint.activate([
                cell.leadingAnchor.constraint(equalTo: gridCellView.leadingAnchor, constant: 4),
                trailing,
                cell.centerYAnchor.constraint(equalTo: gridCellView.centerYAnchor),

                fkButton.trailingAnchor.constraint(equalTo: gridCellView.trailingAnchor, constant: -4),
                fkButton.centerYAnchor.constraint(equalTo: gridCellView.centerYAnchor),
                fkButton.widthAnchor.constraint(equalToConstant: 16),
                fkButton.heightAnchor.constraint(equalToConstant: 16),

                chevron.trailingAnchor.constraint(equalTo: gridCellView.trailingAnchor, constant: -4),
                chevron.centerYAnchor.constraint(equalTo: gridCellView.centerYAnchor),
                chevron.widthAnchor.constraint(equalToConstant: 10),
                chevron.heightAnchor.constraint(equalToConstant: 12),
            ])
        }

        cell.lineBreakMode = .byTruncatingTail
        cell.maximumNumberOfLines = 1
        cell.cell?.truncatesLastVisibleLine = true
        cell.cell?.usesSingleLineMode = true

        let showFK = isFKColumn && rawValue != nil && rawValue?.isEmpty != true
        let showChevron = isDropdown

        if let fkButton = gridCellView.fkArrowButton {
            fkButton.isHidden = !showFK
            if showFK {
                fkButton.target = fkArrowTarget
                fkButton.action = fkArrowAction
                fkButton.fkRow = row
                fkButton.fkColumnIndex = columnIndex
            }
        }

        if let chevron = gridCellView.chevronButton {
            chevron.isHidden = !showChevron
            if showChevron {
                chevron.cellRow = row
                chevron.cellColumnIndex = columnIndex
                chevron.target = chevronTarget
                chevron.action = chevronAction
            }
        }

        if showFK {
            gridCellView.textFieldTrailing?.constant = -22
        } else if showChevron {
            gridCellView.textFieldTrailing?.constant = -18
        } else {
            gridCellView.textFieldTrailing?.constant = -4
        }

        cell.isEditable = isEditable
        cell.delegate = delegate
        cell.identifier = cellIdentifier

        let isDeleted = visualState.isDeleted
        let isInserted = visualState.isInserted
        let isModified = visualState.modifiedColumns.contains(columnIndex)

        configureTextContent(cell: cell, displayValue: displayValue, rawValue: rawValue, isLargeDataset: isLargeDataset)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if isDeleted {
            gridCellView.changeBackgroundColor = ThemeEngine.shared.colors.dataGrid.deleted
        } else if isInserted {
            gridCellView.changeBackgroundColor = ThemeEngine.shared.colors.dataGrid.inserted
        } else if isModified {
            gridCellView.changeBackgroundColor = ThemeEngine.shared.colors.dataGrid.modified
        } else {
            gridCellView.changeBackgroundColor = nil
        }

        gridCellView.isFocusedCell = isFocused

        CATransaction.commit()

        let accessibilityValue = rawValue ?? String(localized: "NULL")
        cell.setAccessibilityLabel(
            String(format: String(localized: "Row %d, column %d: %@"), row + 1, columnIndex + 1, accessibilityValue)
        )
        gridCellView.setAccessibilityRowIndexRange(NSRange(location: row, length: 1))
        gridCellView.setAccessibilityColumnIndexRange(NSRange(location: columnIndex, length: 1))

        return gridCellView
    }

    // MARK: - Button Creation

    private func createFKArrowButton() -> FKArrowButton {
        let button = FKArrowButton()
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = NSImage(
            systemSymbolName: "arrow.right.circle.fill",
            accessibilityDescription: String(localized: "Navigate to referenced row")
        )
        button.contentTintColor = .tertiaryLabelColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.imageScaling = .scaleProportionallyDown
        button.isHidden = true
        return button
    }

    private func createChevronButton() -> CellChevronButton {
        let chevron = CellChevronButton()
        chevron.bezelStyle = .inline
        chevron.isBordered = false
        chevron.image = NSImage(
            systemSymbolName: "chevron.up.chevron.down",
            accessibilityDescription: String(localized: "Open editor")
        )
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        chevron.imageScaling = .scaleProportionallyDown
        chevron.isHidden = true
        return chevron
    }

    // MARK: - Cell Text Content

    private func configureTextContent(
        cell: NSTextField,
        displayValue: String?,
        rawValue: String?,
        isLargeDataset: Bool
    ) {
        cell.placeholderString = nil

        let cellTextField = cell as? CellTextField

        if rawValue == nil {
            cell.stringValue = ""
            cellTextField?.originalValue = nil
            cell.font = ThemeEngine.shared.dataGridFonts.italic
            cell.tag = DataGridFontVariant.italic
            if !isLargeDataset {
                cell.placeholderString = nullDisplayString
            }
            cell.textColor = .secondaryLabelColor
        } else if rawValue == "__DEFAULT__" {
            cell.stringValue = ""
            cellTextField?.originalValue = nil
            cell.font = ThemeEngine.shared.dataGridFonts.medium
            cell.tag = DataGridFontVariant.medium
            if !isLargeDataset {
                cell.placeholderString = "DEFAULT"
            }
            cell.textColor = .systemBlue
        } else if rawValue == "" {
            cell.stringValue = ""
            cellTextField?.originalValue = nil
            cell.font = ThemeEngine.shared.dataGridFonts.italic
            cell.tag = DataGridFontVariant.italic
            if !isLargeDataset {
                cell.placeholderString = "Empty"
            }
            cell.textColor = .secondaryLabelColor
        } else {
            cell.stringValue = displayValue ?? ""
            cellTextField?.originalValue = rawValue
            cell.textColor = .labelColor
            cell.font = ThemeEngine.shared.dataGridFonts.regular
            cell.tag = DataGridFontVariant.regular
        }
    }

    // MARK: - Column Width Calculation

    /// Minimum column width
    private static let minColumnWidth: CGFloat = 60
    /// Maximum column width - prevents overly wide columns
    private static let maxColumnWidth: CGFloat = 800
    /// Number of rows to sample for width calculation (for performance)
    private static let sampleRowCount = 30
    /// Maximum characters to consider per cell for width estimation
    private static let maxMeasureChars = 50
    /// Font for measuring header
    private var headerFont: NSFont {
        NSFont.systemFont(ofSize: 13, weight: .semibold)
    }

    /// Calculate column width based on header name only (used for initial display)
    func calculateColumnWidth(for columnName: String) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: headerFont]
        let size = (columnName as NSString).size(withAttributes: attributes)
        let width = size.width + 48 // padding for sort indicator + margins
        return min(max(width, Self.minColumnWidth), Self.maxColumnWidth)
    }

    /// Calculate optimal column width based on header and cell content.
    ///
    /// Since the cell font is monospaced, we avoid per-row CoreText measurement
    /// and instead multiply character count by the pre-computed glyph advance width.
    /// This reduces the cost from O(sampleRows * CoreText) to O(sampleRows * 1).
    ///
    /// - Parameters:
    ///   - columnName: The column header name
    ///   - columnIndex: Index of the column
    ///   - rowProvider: Provider to get sample row data
    /// - Returns: Optimal column width within min/max bounds
    func calculateOptimalColumnWidth(
        for columnName: String,
        columnIndex: Int,
        rowProvider: InMemoryRowProvider
    ) -> CGFloat {
        // For header: use character count * average proportional char width
        // instead of CoreText measurement. ~0.6 of mono width is a good estimate
        // for proportional system font.
        let headerCharCount = (columnName as NSString).length
        var maxWidth = CGFloat(headerCharCount) * ThemeEngine.shared.dataGridFonts.monoCharWidth * 0.75 + 48

        let totalRows = rowProvider.totalRowCount
        let columnCount = rowProvider.columns.count
        // Reduce sample count for wide tables to keep total work bounded
        let effectiveSampleCount = columnCount > 50 ? 10 : Self.sampleRowCount
        let step = max(1, totalRows / effectiveSampleCount)
        let charWidth = ThemeEngine.shared.dataGridFonts.monoCharWidth

        for i in stride(from: 0, to: totalRows, by: step) {
            guard let value = rowProvider.value(atRow: i, column: columnIndex) else { continue }

            let charCount = min((value as NSString).length, Self.maxMeasureChars)
            let cellWidth = CGFloat(charCount) * charWidth + 16
            maxWidth = max(maxWidth, cellWidth)

            if maxWidth >= Self.maxColumnWidth {
                return Self.maxColumnWidth
            }
        }

        return min(max(maxWidth, Self.minColumnWidth), Self.maxColumnWidth)
    }

    /// Calculate column width to fit content without max-width or max-chars caps.
    /// Used for user-initiated "Size to Fit" (double-click divider, context menu).
    func calculateFitToContentWidth(
        for columnName: String,
        columnIndex: Int,
        rowProvider: InMemoryRowProvider
    ) -> CGFloat {
        let headerCharCount = (columnName as NSString).length
        var maxWidth = CGFloat(headerCharCount) * ThemeEngine.shared.dataGridFonts.monoCharWidth * 0.75 + 48

        let totalRows = rowProvider.totalRowCount
        let columnCount = rowProvider.columns.count
        let effectiveSampleCount = columnCount > 50 ? 10 : Self.sampleRowCount
        let step = max(1, totalRows / effectiveSampleCount)
        let charWidth = ThemeEngine.shared.dataGridFonts.monoCharWidth

        for i in stride(from: 0, to: totalRows, by: step) {
            guard let value = rowProvider.value(atRow: i, column: columnIndex) else { continue }

            let charCount = (value as NSString).length
            let cellWidth = CGFloat(charCount) * charWidth + 16
            maxWidth = max(maxWidth, cellWidth)
        }

        return max(maxWidth, Self.minColumnWidth)
    }
}

// MARK: - NSFont Extension

extension NSFont {
    func withTraits(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}

// MARK: - String Extension for Cell Display

internal extension String {
    /// Whether the string contains any Unicode line-break character
    /// (LF, CR, VT, FF, NEL, LS, PS). Uses NSString UTF-16 loop for O(1) per-char access.
    var containsLineBreak: Bool {
        let nsString = self as NSString
        let length = nsString.length
        guard length > 0 else { return false }
        for i in 0..<length {
            let ch = nsString.character(at: i)
            if ch == 0x0A || ch == 0x0D || ch == 0x0B || ch == 0x0C ||
               ch == 0x85 || ch == 0x2028 || ch == 0x2029 {
                return true
            }
        }
        return false
    }

    /// Sanitize string for single-line cell display by replacing line-break characters with spaces.
    /// Covers: LF (0x0A), CR (0x0D), VT (0x0B), FF (0x0C), NEL (0x85), LS (0x2028), PS (0x2029).
    /// Uses NSString UTF-16 loop for O(1) per-character access (project convention for large strings).
    var sanitizedForCellDisplay: String {
        let nsString = self as NSString
        let length = nsString.length
        guard length > 0 else { return self }

        guard containsLineBreak else { return self }

        // Slow path: build new string with line breaks replaced by spaces
        let mutable = NSMutableString(capacity: length)
        for i in 0..<length {
            let ch = nsString.character(at: i)
            if ch == 0x0A || ch == 0x0D || ch == 0x0B || ch == 0x0C ||
               ch == 0x85 || ch == 0x2028 || ch == 0x2029 {
                mutable.append(" ")
            } else {
                mutable.append(String(utf16CodeUnits: [ch], count: 1))
            }
        }
        return mutable as String
    }
}
