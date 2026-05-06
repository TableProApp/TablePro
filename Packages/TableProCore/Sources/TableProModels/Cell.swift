import Foundation

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
            return head + "... (\(byteCountFormatter.string(fromByteCount: Int64(total))))"
        case .binary(let count, _):
            return "[BLOB \(byteCountFormatter.string(fromByteCount: Int64(count)))]"
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

    public init(table: String, column: String, primaryKey: [PrimaryKeyComponent]) {
        self.table = table
        self.column = column
        self.primaryKey = primaryKey
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

    public init(cells: [Cell]) {
        self.cells = cells
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
}

public extension Cell {
    static func from(legacyValue value: String?, columnTypeName: String?, options: StreamOptions, ref: CellRef? = nil) -> Cell {
        guard let value else { return .null }
        let bytes = value.utf8.count
        let upper = (columnTypeName ?? "").uppercased()
        let isBinary = upper.contains("BLOB") || upper.contains("BYTEA") || upper.contains("BINARY") || upper.contains("VARBINARY") || upper.contains("IMAGE")

        if isBinary {
            return .binary(byteCount: bytes, ref: ref)
        }

        if bytes > options.textTruncationBytes {
            let prefixSlice = value.prefix(options.textTruncationBytes)
            return .truncatedText(prefix: String(prefixSlice), totalBytes: bytes, ref: ref)
        }

        return .text(value)
    }
}

private let byteCountFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
    formatter.countStyle = .binary
    return formatter
}()
