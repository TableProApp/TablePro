import Foundation
import TableProWeaviateCore

extension WeaviateGraphQL {
    public static func getQuery(
        collection: String,
        properties: [String],
        limit: Int,
        offset: Int,
        sorts: [WeaviateSortSpec],
        filters: [WeaviateFilterSpec],
        logicMode: String,
        schema: [String: WeaviateProperty],
        includeVector: Bool = true
    ) throws -> String {
        let types = schema.mapValues(\.dataType)
        let fields = properties
            .filter { $0 != WeaviateSchema.uuidColumn && $0 != WeaviateSchema.vectorColumn }
            .compactMap { selection(for: $0, schema: schema) }
            .joined(separator: " ")
        var args: [String] = ["limit: \(max(limit, 0))", "offset: \(max(offset, 0))"]
        if let whereClause = try WeaviateFilterBuilder.graphQLWhere(
            filters: filters, logicMode: logicMode, types: types
        ) {
            args.append("where: \(whereClause)")
        }
        let sortArgs = sorts.compactMap { sort -> String? in
            guard let path = sortPath(for: sort) else { return nil }
            let order = sort.ascending ? "asc" : "desc"
            return "{ path: [\"\(WeaviateFilterBuilder.escape(path))\"] order: \(order) }"
        }
        if !sortArgs.isEmpty {
            args.append("sort: [\(sortArgs.joined(separator: " "))]")
        }
        let argumentList = args.joined(separator: ", ")
        let additional = includeVector ? "id vector" : "id"
        return """
        { Get { \(collection)(\(argumentList)) { \(fields) _additional { \(additional) } } } }
        """
    }

    /// A structured property needs its own sub-selection, and an `object` with no declared nested
    /// properties has nothing to select, so it is left out rather than failing the query.
    private static func selection(for name: String, schema: [String: WeaviateProperty]) -> String? {
        guard let property = schema[name] else { return name }
        switch WeaviatePropertyShape.of(property) {
        case .scalar:
            return name
        case .geoCoordinates:
            return "\(name) { latitude longitude }"
        case .phoneNumber:
            return "\(name) { input internationalFormatted nationalFormatted countryCode national valid defaultCountry }"
        case .object:
            let nested = property.nestedProperties
                .compactMap { selection(for: $0.name, schema: [$0.name: $0]) }
                .joined(separator: " ")
            return nested.isEmpty ? nil : "\(name) { \(nested) }"
        case .crossReference(let targets):
            let fragments = targets.map { "... on \($0) { _additional { id } }" }.joined(separator: " ")
            return "\(name) { \(fragments) }"
        }
    }

    /// `vector` is a grid column rather than a property, so Weaviate has nothing to sort on. Every
    /// real property is passed through: a type it cannot sort, such as uuid, is reported by the
    /// server, which beats painting a sort chevron over rows in insertion order.
    private static func sortPath(for sort: WeaviateSortSpec) -> String? {
        if sort.column == WeaviateSchema.uuidColumn {
            return WeaviateSchema.uuidGraphQLPath
        }
        return sort.column == WeaviateSchema.vectorColumn ? nil : sort.column
    }
}
