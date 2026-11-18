//
//  SnowflakeShowMetadata.swift
//  TableProSnowflakeCore
//

import Foundation

public struct SnowflakeShowRows: Sendable {
    public let columns: [String]
    public let rows: [[String?]]

    public init(columns: [String], rows: [[String?]]) {
        self.columns = columns
        self.rows = rows
    }

    fileprivate func index(of name: String) -> Int? {
        columns.firstIndex { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
}

public struct SnowflakeShownColumn: Equatable, Sendable {
    public let name: String
    public let dataType: String
    public let isNullable: Bool
    public let defaultValue: String?
    public let comment: String?
}

public struct SnowflakeShownTable: Equatable, Sendable {
    public let rowCount: Int64?
    public let bytes: Int64?
    public let comment: String?
    public let clusterBy: String?
}

// Reads what SHOW COLUMNS and SHOW TABLES answer, which needs no running warehouse. Nil means the answer cannot stand
// in for INFORMATION_SCHEMA, and the caller reads that instead.
public enum SnowflakeShowMetadata {
    public static func columns(from result: SnowflakeShowRows) -> [SnowflakeShownColumn]? {
        guard !result.rows.isEmpty,
              let nameIndex = result.index(of: "column_name"),
              let typeIndex = result.index(of: "data_type")
        else { return nil }
        let nullIndex = result.index(of: "null?")
        let defaultIndex = result.index(of: "default")
        let commentIndex = result.index(of: "comment")

        var columns: [SnowflakeShownColumn] = []
        columns.reserveCapacity(result.rows.count)
        for row in result.rows {
            guard let name = value(row, nameIndex),
                  let type = value(row, typeIndex).flatMap(ShownDataType.init(json:))
            else { return nil }
            columns.append(SnowflakeShownColumn(
                name: name,
                dataType: type.name,
                isNullable: type.isNullable ?? nullIndex.flatMap { flag(value(row, $0)) } ?? true,
                defaultValue: text(row, defaultIndex),
                comment: text(row, commentIndex)
            ))
        }
        return columns
    }

    // LIKE ignores case, so a pattern for `orders` also answers with `ORDERS`.
    public static func table(named name: String, in result: SnowflakeShowRows) -> SnowflakeShownTable? {
        guard let nameIndex = result.index(of: "name"),
              let row = result.rows.first(where: { value($0, nameIndex) == name })
        else { return nil }
        return SnowflakeShownTable(
            rowCount: text(row, result.index(of: "rows")).flatMap { Int64($0) },
            bytes: text(row, result.index(of: "bytes")).flatMap { Int64($0) },
            comment: text(row, result.index(of: "comment")),
            clusterBy: text(row, result.index(of: "cluster_by"))
        )
    }

    private static func value(_ row: [String?], _ index: Int) -> String? {
        index < row.count ? row[index] : nil
    }

    private static func text(_ row: [String?], _ index: Int?) -> String? {
        guard let index, let text = value(row, index), !text.isEmpty else { return nil }
        return text
    }

    private static func flag(_ text: String?) -> Bool? {
        switch text?.lowercased() {
        case "true", "y", "yes": return true
        case "false", "n", "no": return false
        default: return nil
        }
    }
}

// `data_type` is JSON whose `type` uses the internal names, where INFORMATION_SCHEMA says NUMBER and FLOAT.
private struct ShownDataType {
    let name: String
    let isNullable: Bool?

    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String, !type.isEmpty
        else { return nil }
        switch type.uppercased() {
        case "FIXED": name = "NUMBER"
        case "REAL": name = "FLOAT"
        default: name = type.uppercased()
        }
        isNullable = object["nullable"] as? Bool
    }
}
