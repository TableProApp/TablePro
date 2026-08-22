//
//  DataGridCellKind.swift
//  TablePro
//

import AppKit

enum DataGridCellKind: Equatable {
    case text
    case foreignKey
    case dropdown
    case boolean
    case json
    case blob
    case date

    var showsChevron: Bool {
        switch self {
        case .dropdown, .boolean, .json, .blob, .date:
            return true
        case .text, .foreignKey:
            return false
        }
    }
}

enum DataGridCellAccessory: Equatable {
    case none
    case chevron
    case foreignKey

    private static let gap: CGFloat = 4
    private static let minimumSizingTrailingSpace: CGFloat = 8

    var size: NSSize {
        switch self {
        case .none:
            return .zero
        case .chevron:
            return NSSize(width: 12, height: 14)
        case .foreignKey:
            return NSSize(width: 16, height: 16)
        }
    }

    var reservedTrailingWidth: CGFloat {
        guard self != .none else { return 0 }
        return size.width + Self.gap
    }

    var measurementPadding: CGFloat {
        2 * DataGridMetrics.cellHorizontalInset
            + Self.minimumSizingTrailingSpace
            + reservedTrailingWidth
    }

    var columnWidthReservation: CGFloat {
        reservedTrailingWidth
    }

    func frame(in bounds: NSRect) -> NSRect {
        guard self != .none else { return .zero }
        let size = size
        let minRequiredWidth = size.width + 2 * DataGridMetrics.cellHorizontalInset
        guard bounds.width >= minRequiredWidth else { return .zero }
        return NSRect(
            x: bounds.maxX - DataGridMetrics.cellHorizontalInset - size.width,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    func availableTextWidth(in bounds: NSRect) -> CGFloat {
        max(
            0,
            bounds.width
                - 2 * DataGridMetrics.cellHorizontalInset
                - reservedTrailingWidth
        )
    }

    static func reserved(for kind: DataGridCellKind, isEditable: Bool) -> DataGridCellAccessory {
        if kind == .foreignKey {
            return .foreignKey
        }
        return kind.showsChevron && isEditable ? .chevron : .none
    }

    static func visible(
        for kind: DataGridCellKind,
        isEditable: Bool,
        rawValue: String?
    ) -> DataGridCellAccessory {
        if kind == .foreignKey {
            guard let rawValue, !rawValue.isEmpty else { return .none }
            return .foreignKey
        }
        return reserved(for: kind, isEditable: isEditable)
    }
}

struct DataGridColumnPresentation: Equatable {
    let kind: DataGridCellKind
    let accessory: DataGridCellAccessory

    static func resolve(
        columnType: ColumnType?,
        isForeignKey: Bool,
        isDropdown: Bool,
        isTypePicker: Bool,
        isEnumOrSet: Bool,
        isEditable: Bool
    ) -> DataGridColumnPresentation {
        let configuredPicker = isDropdown || isTypePicker
        let picksFromList = configuredPicker || isEnumOrSet || columnType?.isEnumOrSetType == true
        let kind: DataGridCellKind

        if isForeignKey && !configuredPicker {
            kind = .foreignKey
        } else if isEditable && picksFromList {
            kind = .dropdown
        } else if columnType?.isBooleanType == true {
            kind = .boolean
        } else if columnType?.isJsonType == true {
            kind = .json
        } else if columnType?.isBlobType == true {
            kind = .blob
        } else if columnType?.isDateType == true {
            kind = .date
        } else {
            kind = .text
        }

        return DataGridColumnPresentation(
            kind: kind,
            accessory: DataGridCellAccessory.reserved(for: kind, isEditable: isEditable)
        )
    }
}
