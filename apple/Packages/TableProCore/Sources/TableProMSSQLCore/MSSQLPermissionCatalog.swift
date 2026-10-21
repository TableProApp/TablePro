import Foundation

public struct MSSQLPermissionCatalog: Sendable, Equatable {
    public enum Category: Sendable, Equatable {
        case data
        case structure
        case administration
    }

    public let server: [String]
    public let database: [String]
    public let schema: [String]
    public let object: [String]

    public static let column = ["SELECT", "UPDATE", "REFERENCES"]

    // EXECUTE is for modules and RECEIVE for queues, never a table or view.
    static let excludedObjectPermissions: Set<String> = ["EXECUTE", "RECEIVE"]

    private static let dataOrder = ["SELECT", "INSERT", "UPDATE", "DELETE", "EXECUTE"]

    public init(rows: [(classDescription: String, permission: String)]) {
        var byClass: [String: [String]] = [:]
        for row in rows {
            guard let name = MSSQLPermissionName.sanitized(row.permission) else { continue }
            let key = row.classDescription.uppercased()
            if byClass[key]?.contains(name) == true { continue }
            byClass[key, default: []].append(name)
        }
        server = Self.ordered(byClass["SERVER"] ?? [])
        database = Self.ordered(byClass["DATABASE"] ?? [])
        schema = Self.ordered(byClass["SCHEMA"] ?? [])
        object = Self.ordered((byClass["OBJECT"] ?? []).filter { !Self.excludedObjectPermissions.contains($0) })
    }

    public static func category(of permission: String) -> Category {
        if dataOrder.contains(permission) { return .data }
        if permission.hasPrefix("CREATE ") || permission.hasPrefix("ALTER") || permission == "REFERENCES" {
            return .structure
        }
        return .administration
    }

    private static func ordered(_ names: [String]) -> [String] {
        let data = dataOrder.filter(names.contains)
        return data + names.filter { !dataOrder.contains($0) }.sorted()
    }
}
