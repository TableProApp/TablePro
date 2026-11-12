import Foundation
import TableProQdrantCore

public enum QdrantSortPlan: Sendable, Equatable {
    case byID
    case byPayload(column: String, key: String, ascending: Bool)

    public static func resolve(_ sorts: [QdrantSortSpec]) throws -> QdrantSortPlan {
        guard let sort = sorts.first else { return .byID }
        guard sorts.count == 1 else {
            throw QdrantError.unsupported(String(localized: "Qdrant sorts by one field at a time. Remove the sort from the other columns."))
        }
        if sort.column == QdrantSchema.idColumn {
            guard sort.ascending else {
                throw QdrantError.unsupported(String(localized: "Qdrant lists points by id in ascending order only."))
            }
            return .byID
        }
        guard !QdrantSchema.isVectorColumn(sort.column), sort.column != QdrantSchema.scoreColumn else {
            throw QdrantError.unsupported(String(format: String(localized: "Qdrant cannot sort by %@."), sort.column))
        }
        guard let key = QdrantKeyPath.quoted(QdrantSchema.payloadKey(forColumn: sort.column)) else {
            throw QdrantFilterError.keyNotAddressable(column: sort.column)
        }
        return .byPayload(column: sort.column, key: key, ascending: sort.ascending)
    }
}
