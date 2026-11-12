import Foundation
import os

public enum Cell: Sendable {
    case null
    case text(String)
    case truncatedText(prefix: String, totalBytes: Int, ref: CellRef?)
    case binary(byteCount: Int, ref: CellRef?)
}

public extension Cell {
    var displayString: String {
        switch self {
        case .null:
            return "NULL"
        case .text(let value):
            return value
        case .truncatedText(let head, let total, _):
            return head + "... (\(formattedByteCount(total)))"
        case .binary(let count, _):
            return "[BLOB \(formattedByteCount(count))]"
        }
    }

    var isLoadable: Bool {
        switch self {
        case .truncatedText(_, _, let ref), .binary(_, let ref):
            return ref != nil
        case .text, .null:
            return false
        }
    }

    var fullValueRef: CellRef? {
        switch self {
        case .truncatedText(_, _, let ref), .binary(_, let ref):
            return ref
        case .text, .null:
            return nil
        }
    }
}

public struct CellRef: Sendable, Hashable {
    public let table: String
    public let column: String
    public let primaryKey: [PrimaryKeyComponent]
    // The row's `Row.locator`, for a driver that finds a row by it rather than by the key's display text.
    public let locator: String?

    public init(table: String, column: String, primaryKey: [PrimaryKeyComponent], locator: String? = nil) {
        self.table = table
        self.column = column
        self.primaryKey = primaryKey
        self.locator = locator
    }
}

public struct PrimaryKeyComponent: Sendable, Hashable {
    public let column: String
    public let value: String

    public init(column: String, value: String) {
        self.column = column
        self.value = value
    }
}

public struct Row: Sendable {
    public let cells: [Cell]
    // Text the driver that read the row finds it by again, as `PluginQueryResult.rowLocators` holds it.
    public let locator: String?

    public init(cells: [Cell], locator: String? = nil) {
        self.cells = cells
        self.locator = locator
    }
}

public extension Row {
    var legacyValues: [String?] {
        cells.map { cell -> String? in
            switch cell {
            case .null:
                return nil
            case .text(let value):
                return value
            case .truncatedText, .binary:
                return cell.displayString
            }
        }
    }

    // A one-line list never needs more than a preview, even of a value the cell holds whole.
    func displayValues(maxBytes: Int = Cell.previewByteLimit) -> [String?] {
        cells.map { cell -> String? in
            switch cell {
            case .null:
                return nil
            case .text(let value):
                return Cell.preview(of: value, maxBytes: maxBytes)
            case .truncatedText, .binary:
                return cell.displayString
            }
        }
    }
}

public extension Cell {
    static let previewByteLimit = 4_096

    // For text whose kind only the column's declared type tells, such as a row read back as strings.
    static func from(legacyValue value: String?, columnTypeName: String?, options: StreamOptions, ref: CellRef? = nil) -> Cell {
        guard let value else { return .null }
        if let columnTypeName, holdsBytes(typeName: columnTypeName) {
            return .binary(byteCount: value.utf8.count, ref: ref)
        }
        return from(text: value, options: options, ref: ref)
    }

    // For a value the driver knows is text, whatever its column's type is called.
    static func from(text value: String, options: StreamOptions, ref: CellRef? = nil) -> Cell {
        let bytes = value.utf8.count
        guard bytes > options.textTruncationBytes else { return .text(value) }
        // A value with a ref can be read again by its key, so it never spends the budget.
        if ref == nil, let budget = options.textBudget, budget.admit(bytes) {
            return .text(value)
        }
        return .truncatedText(prefix: preview(of: value, maxBytes: options.textTruncationBytes), totalBytes: bytes, ref: ref)
    }

    // At most `maxBytes` of UTF-8, ending on a Character boundary.
    static func preview(of value: String, maxBytes: Int) -> String {
        guard value.utf8.count > maxBytes else { return value }
        var end = value.startIndex
        var used = 0
        while end < value.endIndex {
            let next = value.index(after: end)
            used += value.utf8.distance(from: end, to: next)
            guard used <= maxBytes else { break }
            end = next
        }
        return String(value[..<end])
    }

    // Whole names only: Oracle's BINARY_DOUBLE, BINARY_FLOAT and BINARY_INTEGER hold numbers.
    static func holdsBytes(typeName: String) -> Bool {
        let base = typeName.prefix { $0 != "(" }.trimmingCharacters(in: .whitespaces).uppercased()
        return byteTypeNames.contains(base)
    }

    private static let byteTypeNames: Set<String> = [
        "BLOB", "TINYBLOB", "MEDIUMBLOB", "LONGBLOB", "BYTEA", "BINARY", "VARBINARY", "IMAGE"
    ]
}

private let byteCountFormatter = OSAllocatedUnfairLock(uncheckedState: {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
    formatter.countStyle = .binary
    return formatter
}())

private func formattedByteCount(_ byteCount: Int) -> String {
    byteCountFormatter.withLock { $0.string(fromByteCount: Int64(byteCount)) }
}
