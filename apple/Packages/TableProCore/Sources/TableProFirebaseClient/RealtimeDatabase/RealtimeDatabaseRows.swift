import Foundation
import TableProFirebaseCore

public struct RealtimeDatabaseRowSet: Sendable, Equatable {
    public let columns: [String]
    public let columnTypes: [String]
    public let rows: [[String?]]
    public let locators: [String]
    public let absentCells: [Int: Set<Int>]
    public let cellTypes: [String: [String: String]]

    public init(children: [(key: String, value: FirebaseJSON)], nodePath: String) {
        let fieldNames = Set(children.flatMap { $0.value.objectValue?.keys.map { $0 } ?? [] }).sorted()
        let hasPlainValues = children.contains { $0.value.objectValue == nil }
        var columns = [RealtimeDatabaseQueryPlanner.keyColumn] + fieldNames
        if hasPlainValues || children.isEmpty {
            columns.append(RealtimeDatabaseQueryPlanner.valueColumn)
        }
        var rows: [[String?]] = []
        var absent: [Int: Set<Int>] = [:]
        var cellTypes: [String: [String: String]] = [:]
        var typeVotes: [[String: Int]] = Array(repeating: [:], count: columns.count)
        for (rowIndex, child) in children.enumerated() {
            let locator = RealtimeDatabasePath.join(nodePath, child.key)
            var row: [String?] = [child.key.isEmpty ? RealtimeDatabasePath.nodeKey(nodePath) : child.key]
            var types: [String: String] = [:]
            let members = child.value.objectValue
            for (offset, column) in columns.enumerated().dropFirst() {
                let cell: FirebaseJSON?
                if column == RealtimeDatabaseQueryPlanner.valueColumn {
                    cell = members == nil ? child.value : nil
                } else {
                    cell = members?[column]
                }
                guard let cell else {
                    row.append(nil)
                    absent[rowIndex, default: []].insert(offset)
                    continue
                }
                row.append(Self.text(cell))
                let type = RealtimeDatabaseTypeName.of(cell)
                types[column] = type
                typeVotes[offset][type, default: 0] += 1
            }
            rows.append(row)
            cellTypes[locator] = types
        }
        self.columns = columns
        self.columnTypes = typeVotes.enumerated().map { index, votes in
            guard index > 0 else { return RealtimeDatabaseTypeName.string }
            return votes.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
                ?? RealtimeDatabaseTypeName.string
        }
        self.rows = rows
        self.locators = children.map { RealtimeDatabasePath.join(nodePath, $0.key) }
        self.absentCells = absent
        self.cellTypes = cellTypes
    }

    static func text(_ value: FirebaseJSON) -> String? {
        switch value {
        case .null: return nil
        case .string(let text): return text
        case .bool(let flag): return flag ? "true" : "false"
        case .int(let number): return String(number)
        case .double(let number): return "\(number)"
        case .array, .object: return value.text()
        }
    }
}

public enum RealtimeDatabaseCell {
    /// A string cell stays a string; anything else is read as a JSON literal.
    public static func value(text: String, typeName: String?) throws -> FirebaseJSON {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch typeName {
        case RealtimeDatabaseTypeName.string:
            return .string(text)
        case RealtimeDatabaseTypeName.number:
            guard let json = try? FirebaseJSON.parse(trimmed), case .int = json else {
                guard let number = Double(trimmed), number.isFinite else {
                    throw FirebaseError.configuration(String(format: String(localized: "\"%@\" is not a number."), text))
                }
                return .double(number)
            }
            return json
        case RealtimeDatabaseTypeName.boolean:
            switch trimmed.lowercased() {
            case "true", "1": return .bool(true)
            case "false", "0": return .bool(false)
            default: throw FirebaseError.configuration(String(format: String(localized: "\"%@\" is not true or false."), text))
            }
        case RealtimeDatabaseTypeName.object, RealtimeDatabaseTypeName.array:
            return try FirebaseJSON.parse(trimmed)
        default:
            if let first = trimmed.first, "{[-0123456789tfn\"".contains(first), let json = try? FirebaseJSON.parse(trimmed) {
                return json
            }
            return .string(text)
        }
    }
}
