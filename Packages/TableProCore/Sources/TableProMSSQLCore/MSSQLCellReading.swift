import Foundation

public enum MSSQLCellReading: Equatable, Sendable {
    case null
    case bytes
    case emptyText
    case text
    /// `dbconvert` reads a `sql_variant`'s value bytes as the struct that describes them: measured, a crash on crafted
    /// bytes and a copy of process memory on others.
    case unreadable

    /// `dbdatlen` is 0 for NULL and for an empty value alike. Only a missing `dbdata` pointer is NULL.
    public init(type: MSSQLColumnType, hasData: Bool, length: Int) {
        guard hasData else {
            self = .null
            return
        }
        if type.isBinary {
            self = .bytes
        } else if type == .sqlVariant {
            self = .unreadable
        } else {
            self = length > 0 ? .text : .emptyText
        }
    }
}
