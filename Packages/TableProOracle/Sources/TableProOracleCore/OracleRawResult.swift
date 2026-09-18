import Foundation

public struct OracleColumnDescriptor: Sendable, Equatable {
    public let name: String
    public let typeName: String

    public init(name: String, typeName: String) {
        self.name = name
        self.typeName = typeName
    }
}

public enum OracleRawCell: Sendable, Equatable {
    case null
    case string(String)
    case bytes(Data)

    public var stringValue: String? {
        switch self {
        case .null: return nil
        case .string(let value): return value
        case .bytes(let data): return String(data: data, encoding: .utf8)
        }
    }
}

public struct OracleRawResult: Sendable {
    public let columns: [OracleColumnDescriptor]
    public let rows: [[OracleRawCell]]
    public let affectedRows: Int
    public let isTruncated: Bool

    public init(
        columns: [OracleColumnDescriptor],
        rows: [[OracleRawCell]],
        affectedRows: Int,
        isTruncated: Bool
    ) {
        self.columns = columns
        self.rows = rows
        self.affectedRows = affectedRows
        self.isTruncated = isTruncated
    }
}

public enum OracleStreamElement: Sendable {
    case header(columns: [OracleColumnDescriptor])
    case rows([[OracleRawCell]])
}
