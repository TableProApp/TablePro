//
//  DatePickerCellEditor.swift
//  TablePro
//
//  Custom date picker popover for editing date/time columns in the data grid.
//

import AppKit

/// NSDatePicker configured for inline date editing in data grid cells
final class DatePickerCellEditor: NSDatePicker {
    var onValueChanged: ((String) -> Void)?

    /// Parsers for common database date formats
    private static let parsers: [DateFormatter] = {
        let formats = [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd",
            "HH:mm:ss",
        ]
        return formats.map { format in
            let parser = DateFormatter()
            parser.dateFormat = format
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.timeZone = TimeZone(secondsFromGMT: 0)
            return parser
        }
    }()

    /// Output formatters for database-compatible date strings
    private static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    private static let timeOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    private var isDateOnly = false
    private var isTimeOnly = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        datePickerStyle = .textFieldAndStepper
        datePickerElements = [.yearMonthDay, .hourMinuteSecond]
        font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        isBezeled = false
        isBordered = false
        drawsBackground = false
        target = self
        action = #selector(valueChanged)
    }

    @objc private func valueChanged() {
        let formatter: DateFormatter
        if isDateOnly {
            formatter = Self.dateOnlyFormatter
        } else if isTimeOnly {
            formatter = Self.timeOnlyFormatter
        } else {
            formatter = Self.dateTimeFormatter
        }
        onValueChanged?(formatter.string(from: dateValue))
    }

    /// Format the current date value using the appropriate formatter
    var formattedValue: String {
        let formatter: DateFormatter
        if isDateOnly {
            formatter = Self.dateOnlyFormatter
        } else if isTimeOnly {
            formatter = Self.timeOnlyFormatter
        } else {
            formatter = Self.dateTimeFormatter
        }
        return formatter.string(from: dateValue)
    }

    func selectValue(_ value: String?, columnType: ColumnType?) {
        // Determine picker elements based on column type
        switch columnType {
        case .date:
            datePickerElements = [.yearMonthDay]
            isDateOnly = true
            isTimeOnly = false
        case .timestamp(let rawType), .datetime(let rawType):
            let raw = rawType?.uppercased() ?? ""
            if raw == "TIME" || raw == "TIMETZ" || raw == "TIME WITHOUT TIME ZONE" || raw == "TIME WITH TIME ZONE" {
                datePickerElements = [.hourMinuteSecond]
                isDateOnly = false
                isTimeOnly = true
            } else {
                datePickerElements = [.yearMonthDay, .hourMinuteSecond]
                isDateOnly = false
                isTimeOnly = false
            }
        default:
            datePickerElements = [.yearMonthDay, .hourMinuteSecond]
            isDateOnly = false
            isTimeOnly = false
        }

        guard let dateString = value, !dateString.isEmpty else {
            dateValue = Date()
            return
        }

        // Try parsing with each known format
        for parser in Self.parsers {
            if let date = parser.date(from: dateString) {
                dateValue = date
                return
            }
        }

        // Fallback to current date if unparseable
        dateValue = Date()
    }
}

// MARK: - Popover Controller

/// Manages showing a date picker in a popover for editing date/time cells
@MainActor
final class DatePickerPopoverController: NSObject, NSPopoverDelegate {
    static let shared = DatePickerPopoverController()

    private var popover: NSPopover?
    private var datePicker: DatePickerCellEditor?
    private var onCommit: ((String) -> Void)?
    private var hasUserEdited = false
    private var originalWasNull = false

    func show(
        relativeTo bounds: NSRect,
        of view: NSView,
        value: String?,
        columnType: ColumnType,
        onCommit: @escaping (String) -> Void
    ) {
        // Close any existing popover
        popover?.close()

        self.onCommit = onCommit
        self.hasUserEdited = false
        self.originalWasNull = (value == nil || value?.isEmpty == true)

        let picker = DatePickerCellEditor()
        picker.selectValue(value, columnType: columnType)
        picker.onValueChanged = { [weak self] _ in
            self?.hasUserEdited = true
        }
        picker.sizeToFit()
        datePicker = picker

        let pickerSize = picker.fittingSize
        let padding: CGFloat = 12
        let contentWidth = pickerSize.width + padding * 2
        let contentHeight = pickerSize.height + padding * 2

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight))
        picker.frame = NSRect(x: padding, y: padding, width: pickerSize.width, height: pickerSize.height)
        contentView.addSubview(picker)

        let viewController = PopoverContentViewController()
        viewController.view = contentView

        let pop = NSPopover()
        pop.contentViewController = viewController
        pop.contentSize = NSSize(width: contentWidth, height: contentHeight)
        pop.behavior = .semitransient
        pop.delegate = self
        pop.show(relativeTo: bounds, of: view, preferredEdge: .maxY)

        popover = pop
    }

    func popoverDidClose(_ notification: Notification) {
        // Always commit when original was NULL (any date is a change),
        // otherwise only commit if user actually edited the picker
        if originalWasNull || hasUserEdited, let picker = datePicker {
            onCommit?(picker.formattedValue)
        }
        cleanup()
    }

    private func cleanup() {
        datePicker = nil
        onCommit = nil
        hasUserEdited = false
        originalWasNull = false
        popover = nil
    }
}

// MARK: - Popover Content View Controller

/// Minimal NSViewController subclass with proper loadView override.
/// Avoids bare NSViewController() which bypasses the view controller lifecycle.
private final class PopoverContentViewController: NSViewController {
    override func loadView() {
        self.view = NSView()
    }
}
