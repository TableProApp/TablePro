import Foundation

public struct MSSQLColumnDescriptor: Sendable, Equatable {
    public let name: String
    public let type: MSSQLColumnType

    public init(name: String, type: MSSQLColumnType) {
        self.name = name
        self.type = type
    }
}

public enum MSSQLRawCell: Sendable, Equatable {
    case null
    case string(String)
    case bytes(Data)

    public var stringValue: String? {
        switch self {
        case .null: return nil
        case .string(let s): return s
        case .bytes(let d): return String(data: d, encoding: .utf8)
        }
    }
}

public struct MSSQLRawResult: Sendable {
    public let columns: [MSSQLColumnDescriptor]
    public let rows: [[MSSQLRawCell]]
    public let affectedRows: Int
    public let isTruncated: Bool

    public init(columns: [MSSQLColumnDescriptor], rows: [[MSSQLRawCell]], affectedRows: Int, isTruncated: Bool) {
        self.columns = columns
        self.rows = rows
        self.affectedRows = affectedRows
        self.isTruncated = isTruncated
    }
}

public enum MSSQLStreamElement: Sendable {
    case header(columns: [MSSQLColumnDescriptor])
    case rows([[MSSQLRawCell]])
    case affectedRows(Int)
}
