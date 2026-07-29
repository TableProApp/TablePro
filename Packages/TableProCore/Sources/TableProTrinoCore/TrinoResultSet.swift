import Foundation

public struct TrinoColumnDescriptor: Sendable, Equatable {
    public let name: String
    public let typeName: String
    public let category: TrinoTypeCategory

    public init(name: String, typeName: String, category: TrinoTypeCategory) {
        self.name = name
        self.typeName = typeName
        self.category = category
    }
}

public struct TrinoResultSet: Sendable {
    public let columns: [TrinoColumnDescriptor]
    public let rows: [[TrinoValue]]
    public let updateType: String?
    public let updateCount: Int?
    public let queryId: String?

    public init(
        columns: [TrinoColumnDescriptor],
        rows: [[TrinoValue]],
        updateType: String? = nil,
        updateCount: Int? = nil,
        queryId: String? = nil
    ) {
        self.columns = columns
        self.rows = rows
        self.updateType = updateType
        self.updateCount = updateCount
        self.queryId = queryId
    }

    public var isEmpty: Bool {
        columns.isEmpty && rows.isEmpty
    }
}
