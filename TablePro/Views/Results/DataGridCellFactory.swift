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

/// Factory for creating data grid cell views
@MainActor
final class DataGridCellFactory {
    private let cellIdentifier = NSUserInterfaceItemIdentifier("DataCell")
    private let rowNumberCellIdentifier = NSUserInterfaceItemIdentifier("RowNumberCell")

    /// Large dataset threshold - above this, disable expensive visual features
    private let largeDatasetThreshold = 5_000

    // MARK: - Cached Settings

    /// Cached NULL display string (updated via settings notification)
    private var nullDisplayString: String = AppSettingsManager.shared.dataGrid.nullDisplay
    private var settingsObserver: NSObjectProtocol?

    // MARK: - Cached VoiceOver State

    private static var cachedVoiceOverEnabled: Bool = NSWorkspace.shared.isVoiceOverEnabled
    // Observer lives for app lifetime — no removal needed since DataGridCellFactory is a static singleton cache
    private static let voiceOverObserver: NSObjectProtocol? = {
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                DataGridCellFactory.cachedVoiceOverEnabled = NSWorkspace.shared.isVoiceOverEnabled
            }
        }
    }()

    init() {
        _ = Self.voiceOverObserver

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
        if Self.cachedVoiceOverEnabled {
            cellView.setAccessibilityLabel(String(format: String(localized: "Row %d"), row + 1))
        }

        return cellView
    }

    // MARK: - Data Cell

    private static let chevronTag = 999
    private static let fkArrowTag = 998

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
        let cellViewId: NSUserInterfaceItemIdentifier
        if isDropdown {
            cellViewId = NSUserInterfaceItemIdentifier("DropdownCellView")
        } else if isFKColumn {
            cellViewId = NSUserInterfaceItemIdentifier("FKArrowCellView")
        } else {
            cellViewId = NSUserInterfaceItemIdentifier("DataCellView")
        }
        let cellView: NSTableCellView
        let cell: NSTextField
        let isNewCell: Bool

        if let reused = tableView.makeView(withIdentifier: cellViewId, owner: nil) as? NSTableCellView,
           let textField = reused.textField {
            cellView = reused
            cell = textField
            isNewCell = false
        } else {
            cellView = DataGridCellView()
            cellView.identifier = cellViewId
            cellView.wantsLayer = true

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

            cellView.textField = cell
            cellView.addSubview(cell)

            if isDropdown {
                let chevron = CellChevronButton()
                chevron.tag = Self.chevronTag
                chevron.bezelStyle = .inline
                chevron.isBordered = false
                chevron.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: String(localized: "Open editor"))
                chevron.contentTintColor = .tertiaryLabelColor
                chevron.translatesAutoresizingMaskIntoConstraints = false
                chevron.setContentHuggingPriority(.required, for: .horizontal)
                chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
                chevron.imageScaling = .scaleProportionallyDown
                cellView.addSubview(chevron)

                NSLayoutConstraint.activate([
                    cell.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 4),
                    cell.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -2),
                    cell.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
                    chevron.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -4),
                    chevron.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
                    chevron.widthAnchor.constraint(equalToConstant: 10),
                    chevron.heightAnchor.constraint(equalToConstant: 12),
                ])
            } else if isFKColumn {
                let button = FKArrowButton()
                button.tag = Self.fkArrowTag
                button.bezelStyle = .inline
                button.isBordered = false
                button.image = NSImage(systemSymbolName: "arrow.right.circle.fill", accessibilityDescription: String(localized: "Navigate to referenced row"))
                button.contentTintColor = .tertiaryLabelColor
                button.translatesAutoresizingMaskIntoConstraints = false
                button.setContentHuggingPriority(.required, for: .horizontal)
                button.setContentCompressionResistancePriority(.required, for: .horizontal)
                button.imageScaling = .scaleProportionallyDown
                cellView.addSubview(button)

                NSLayoutConstraint.activate([
                    cell.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 4),
                    cell.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -2),
                    cell.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
                    button.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -4),
                    button.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
                    button.widthAnchor.constraint(equalToConstant: 16),
                    button.heightAnchor.constraint(equalToConstant: 16),
                ])
            } else {
                NSLayoutConstraint.activate([
                    cell.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 4),
                    cell.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -4),
                    cell.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
                ])
            }
            isNewCell = true
        }

        if !isNewCell && (
            cell.lineBreakMode != .byTruncatingTail ||
            cell.maximumNumberOfLines != 1 ||
            cell.cell?.truncatesLastVisibleLine != true ||
            cell.cell?.usesSingleLineMode != true
        ) {
            cell.lineBreakMode = .byTruncatingTail
            cell.maximumNumberOfLines = 1
            cell.cell?.truncatesLastVisibleLine = true
            cell.cell?.usesSingleLineMode = true
        }

        if isFKColumn, let button = cellView.viewWithTag(Self.fkArrowTag) as? FKArrowButton {
            button.target = fkArrowTarget
            button.action = fkArrowAction
            button.fkRow = row
            button.fkColumnIndex = columnIndex
            button.isHidden = (rawValue == nil || rawValue?.isEmpty == true)
        }

        if isDropdown, let chevronButton = cellView.viewWithTag(Self.chevronTag) as? CellChevronButton {
            chevronButton.cellRow = row
            chevronButton.cellColumnIndex = columnIndex
            chevronButton.target = chevronTarget
            chevronButton.action = chevronAction
        }

        cell.isEditable = isEditable
        cell.delegate = delegate
        cell.identifier = cellIdentifier

        let isDeleted = visualState.isDeleted
        let isInserted = visualState.isInserted
        let isModified = visualState.modifiedColumns.contains(columnIndex)

        configureTextContent(cell: cell, displayValue: displayValue, rawValue: rawValue, isLargeDataset: isLargeDataset)

        // Batch layer updates to avoid implicit animations
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Update background color for change states (drawn via DataGridCellView.draw)
        if let gridCell = cellView as? DataGridCellView {
            if isDeleted {
                gridCell.changeBackgroundColor = ThemeEngine.shared.colors.dataGrid.deleted
            } else if isInserted {
                gridCell.changeBackgroundColor = ThemeEngine.shared.colors.dataGrid.inserted
            } else if isModified {
                gridCell.changeBackgroundColor = ThemeEngine.shared.colors.dataGrid.modified
            } else {
                gridCell.changeBackgroundColor = nil
            }
        }

        // Focus ring
        if isLargeDataset {
            cellView.layer?.borderWidth = 0
        } else if isFocused {
            cellView.layer?.borderWidth = 2
            cellView.layer?.borderColor = ThemeEngine.shared.colors.dataGrid.focusBorderCG
        } else {
            cellView.layer?.borderWidth = 0
        }

        CATransaction.commit()

        // Accessibility: describe cell content for VoiceOver
        if !isLargeDataset && Self.cachedVoiceOverEnabled {
            let accessibilityValue = rawValue ?? String(localized: "NULL")
            cell.setAccessibilityLabel(
                String(format: String(localized: "Row %d, column %d: %@"), row + 1, columnIndex + 1, accessibilityValue)
            )
        }

        return cellView
    }

    // MARK: - Cell Text Content

    private func configureTextContent(
        cell: NSTextField,
        displayValue: String?,
        rawValue: String?,
        isLargeDataset: Bool
    ) {
        cell.placeholderString = nil

        if rawValue == nil {
            cell.stringValue = ""
            cell.font = ThemeEngine.shared.dataGridFonts.italic
            cell.tag = DataGridFontVariant.italic
            if !isLargeDataset {
                cell.placeholderString = nullDisplayString
            }
            cell.textColor = .secondaryLabelColor
        } else if rawValue == "__DEFAULT__" {
            cell.stringValue = ""
            cell.font = ThemeEngine.shared.dataGridFonts.medium
            cell.tag = DataGridFontVariant.medium
            if !isLargeDataset {
                cell.placeholderString = "DEFAULT"
            }
            cell.textColor = .systemBlue
        } else if rawValue == "" {
            cell.stringValue = ""
            cell.font = ThemeEngine.shared.dataGridFonts.italic
            cell.tag = DataGridFontVariant.italic
            if !isLargeDataset {
                cell.placeholderString = "Empty"
            }
            cell.textColor = .secondaryLabelColor
        } else {
            cell.stringValue = displayValue ?? ""
            (cell as? CellTextField)?.originalValue = rawValue
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
        NSFont.systemFont(ofSize: ThemeEngine.shared.activeTheme.typography.body, weight: .semibold)
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
