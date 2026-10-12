import Foundation

/// How one page of a Realtime Database node is read. The REST API has no offset and filters on one
/// ordered field at a time, so a page is a server query for the first `offset + limit` children in
/// the requested order, with the leading `offset` dropped here.
public struct RealtimeDatabaseReadPlan: Sendable, Equatable {
    public enum Order: Sendable, Equatable {
        case key
        case value
        case child(String)
    }

    public let order: Order
    public let ascending: Bool
    /// Query parameters other than ordering and limits, already JSON-encoded as the API wants.
    public let bounds: [String: String]
    public let fetchCount: Int
    public let dropCount: Int
    /// The raw filter row, passed through as written.
    public let rawQuery: String?

    public init(order: Order, ascending: Bool, bounds: [String: String], fetchCount: Int, dropCount: Int, rawQuery: String?) {
        self.order = order
        self.ascending = ascending
        self.bounds = bounds
        self.fetchCount = fetchCount
        self.dropCount = dropCount
        self.rawQuery = rawQuery
    }

    public var queryItems: [URLQueryItem] {
        if let rawQuery {
            var items = RealtimeDatabaseReadPlan.parseRawQuery(rawQuery)
            if !items.contains(where: { $0.name.hasPrefix("limitTo") }), fetchCount > 0 {
                items.append(URLQueryItem(name: "limitToFirst", value: String(fetchCount)))
            }
            return items
        }
        var items = [URLQueryItem(name: "orderBy", value: Self.orderParameter(order))]
        for key in bounds.keys.sorted() {
            items.append(URLQueryItem(name: key, value: bounds[key]))
        }
        if fetchCount > 0 {
            items.append(URLQueryItem(name: ascending ? "limitToFirst" : "limitToLast", value: String(fetchCount)))
        }
        return items
    }

    static func orderParameter(_ order: Order) -> String {
        switch order {
        case .key: return "\"$key\""
        case .value: return "\"$value\""
        case .child(let path): return FirebaseJSON.string(path).text()
        }
    }

    static func parseRawQuery(_ text: String) -> [URLQueryItem] {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "?& \n"))
        return trimmed.split(separator: "&").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let name = parts.first, !name.isEmpty else { return nil }
            let value = parts.count > 1 ? (parts[1].removingPercentEncoding ?? parts[1]) : ""
            return URLQueryItem(name: name, value: value)
        }
    }
}

public enum RealtimeDatabaseQueryPlanner {
    public static let keyColumn = "$key"
    public static let valueColumn = "$value"
    public static let rawFilterColumn = "__RAW__"

    public static func plan(spec: FirebaseBrowseSpec, typeOf: (String) -> String?) throws -> RealtimeDatabaseReadPlan {
        let fetchCount = spec.limit > 0 ? spec.offset + spec.limit : 0
        guard spec.filters.count <= 1 else {
            throw FirebaseError.unsupported(String(localized: "The Realtime Database filters on one field at a time. Remove all but one filter, or use a raw filter."))
        }
        let sort = spec.sorts.first
        guard spec.sorts.count <= 1 else {
            throw FirebaseError.unsupported(String(localized: "The Realtime Database sorts by one column at a time."))
        }
        guard let filter = spec.filters.first else {
            let order = sort.map { self.order(for: $0.column) } ?? .key
            return RealtimeDatabaseReadPlan(
                order: order, ascending: sort?.ascending ?? true, bounds: [:],
                fetchCount: fetchCount, dropCount: spec.offset, rawQuery: nil
            )
        }
        if filter.column == rawFilterColumn {
            return RealtimeDatabaseReadPlan(
                order: .key, ascending: true, bounds: [:],
                fetchCount: fetchCount, dropCount: spec.offset, rawQuery: filter.value
            )
        }
        let order = self.order(for: filter.column)
        if let sort, self.order(for: sort.column) != order {
            throw FirebaseError.unsupported(String(localized: "The Realtime Database sorts only by the column it filters on."))
        }
        let columnType = typeOf(filter.column)
        let operand: (String) -> String = { text in
            literal(text, isKey: order == .key, typeName: columnType)
        }
        let bounds: [String: String]
        switch filter.op.uppercased() {
        case "=":
            bounds = ["equalTo": operand(filter.value)]
        case ">=":
            bounds = ["startAt": operand(filter.value)]
        case ">":
            bounds = ["startAfter": operand(filter.value)]
        case "<=":
            bounds = ["endAt": operand(filter.value)]
        case "<":
            bounds = ["endBefore": operand(filter.value)]
        case "BETWEEN":
            guard let upper = filter.secondValue else {
                throw FirebaseError.configuration(String(localized: "BETWEEN needs two values."))
            }
            bounds = ["startAt": operand(filter.value), "endAt": operand(upper)]
        case "STARTS WITH":
            bounds = [
                "startAt": FirebaseJSON.string(filter.value).text(),
                "endAt": FirebaseJSON.string(filter.value + "\u{F8FF}").text()
            ]
        case "IS NULL":
            bounds = ["equalTo": "null"]
        default:
            throw FirebaseError.unsupported(String(
                format: String(localized: "The Realtime Database cannot filter with %@. It supports =, <, <=, >, >=, BETWEEN, STARTS WITH and IS NULL."),
                filter.op
            ))
        }
        return RealtimeDatabaseReadPlan(
            order: order, ascending: sort?.ascending ?? true, bounds: bounds,
            fetchCount: fetchCount, dropCount: spec.offset, rawQuery: nil
        )
    }

    static func order(for column: String) -> RealtimeDatabaseReadPlan.Order {
        switch column {
        case keyColumn: return .key
        case valueColumn: return .value
        default: return .child(column)
        }
    }

    /// A key is always a string. A child value is read by the type the column holds, so `zip =
    /// 02134` stays a string in a string column and `age = 30` is the number 30.
    static func literal(_ text: String, isKey: Bool, typeName: String?) -> String {
        if isKey || typeName == RealtimeDatabaseTypeName.string {
            return FirebaseJSON.string(text).text()
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if typeName == RealtimeDatabaseTypeName.boolean || trimmed == "true" || trimmed == "false" {
            if trimmed.lowercased() == "true" { return "true" }
            if trimmed.lowercased() == "false" { return "false" }
        }
        if typeName != RealtimeDatabaseTypeName.boolean, let number = Double(trimmed), number.isFinite {
            return Int64(exactly: number).map(String.init) ?? FirebaseJSON.doubleText(number)
        }
        return FirebaseJSON.string(text).text()
    }
}

public enum RealtimeDatabaseTypeName {
    public static let string = "string"
    public static let number = "number"
    public static let boolean = "boolean"
    public static let object = "object"
    public static let array = "array"
    public static let null = "null"

    public static func of(_ json: FirebaseJSON) -> String {
        switch json {
        case .null: return null
        case .bool: return boolean
        case .int, .double: return number
        case .string: return string
        case .array: return array
        case .object: return object
        }
    }
}

/// The order the Realtime Database itself sorts in, which the REST API does not keep: it answers
/// a query with a JSON object, so the order has to be restored here.
public enum RealtimeDatabaseOrdering {
    /// Keys that read as 32-bit integers come first in numeric order, then the rest as strings.
    public static func keyPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        switch (Int32(lhs).flatMap { canonical(lhs) ? $0 : nil }, Int32(rhs).flatMap { canonical(rhs) ? $0 : nil }) {
        case let (left?, right?): return left < right
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): return lhs < rhs
        }
    }

    private static func canonical(_ key: String) -> Bool {
        guard let value = Int32(key) else { return false }
        return String(value) == key
    }

    /// null, false, true, numbers, strings, then objects; ties fall back to the key.
    public static func valuePrecedes(_ lhs: (key: String, value: FirebaseJSON?), _ rhs: (key: String, value: FirebaseJSON?)) -> Bool {
        let left = rank(lhs.value), right = rank(rhs.value)
        if left != right { return left < right }
        switch (lhs.value, rhs.value) {
        case let (.int(a)?, .int(b)?) where a != b: return a < b
        case let (.double(a)?, .double(b)?) where a != b: return a < b
        case let (.int(a)?, .double(b)?) where Double(a) != b: return Double(a) < b
        case let (.double(a)?, .int(b)?) where a != Double(b): return a < Double(b)
        case let (.string(a)?, .string(b)?) where a != b: return a < b
        default: return keyPrecedes(lhs.key, rhs.key)
        }
    }

    private static func rank(_ value: FirebaseJSON?) -> Int {
        switch value {
        case nil, .null?: return 0
        case .bool(false)?: return 1
        case .bool(true)?: return 2
        case .int?, .double?: return 3
        case .string?: return 4
        case .array?, .object?: return 5
        }
    }

    public static func value(of child: FirebaseJSON, at order: RealtimeDatabaseReadPlan.Order) -> FirebaseJSON? {
        switch order {
        case .key: return nil
        case .value: return child
        case .child(let path):
            var current: FirebaseJSON? = child
            for segment in path.split(separator: "/") {
                current = current?[String(segment)]
            }
            return current
        }
    }

    public static func sort(
        _ children: [(key: String, value: FirebaseJSON)],
        order: RealtimeDatabaseReadPlan.Order,
        ascending: Bool
    ) -> [(key: String, value: FirebaseJSON)] {
        let sorted = children.sorted { lhs, rhs in
            if order == .key { return keyPrecedes(lhs.key, rhs.key) }
            return valuePrecedes(
                (lhs.key, value(of: lhs.value, at: order)),
                (rhs.key, value(of: rhs.value, at: order))
            )
        }
        return ascending ? sorted : sorted.reversed()
    }
}
