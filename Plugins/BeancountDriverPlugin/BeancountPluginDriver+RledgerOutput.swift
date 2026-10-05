//
//  BeancountPluginDriver+RledgerOutput.swift
//  BeancountDriverPlugin
//

import Foundation
import TableProNumberFormatting
import TableProPluginKit

extension BeancountPluginDriver {
    private static var invalidRledgerOutput: BeancountDriverError {
        .queryFailed(String(localized: "Invalid rustledger JSON output"))
    }

    // rledger 0.22 writes each row as an object keyed by column name. From 0.23 a row is an array
    // positional against `columns`, because BQL can return two columns with the same name.
    private static func parseRledgerJSON(_ data: Data) throws -> (columns: [String]?, rows: [Any]) {
        guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw invalidRledgerOutput
        }
        let columns = dictionary["columns"] as? [String]
        guard let rows = dictionary["rows"] else { return (columns, []) }
        guard let rows = rows as? [Any] else { throw invalidRledgerOutput }
        return (columns, rows)
    }

    private static func positionalValues(_ row: Any, columns: [String]) throws -> [Any?] {
        if let values = row as? [Any] {
            return columns.indices.map { values.indices.contains($0) ? values[$0] : nil }
        }
        if let keyed = row as? [String: Any] {
            return columns.map { keyed[$0] }
        }
        throw invalidRledgerOutput
    }

    static func decodeRledgerColumns(_ data: Data) throws -> [String] {
        guard let columns = try parseRledgerJSON(data).columns else { throw invalidRledgerOutput }
        return columns
    }

    static func decodeRledgerRows(_ data: Data) throws -> [[String: Any]] {
        let parsed = try parseRledgerJSON(data)
        return try parsed.rows.map { row in
            if let keyed = row as? [String: Any] {
                return keyed
            }
            guard let columns = parsed.columns else { throw invalidRledgerOutput }
            let values = try positionalValues(row, columns: columns)
            var keyed: [String: Any] = [:]
            for (column, value) in zip(columns, values) where keyed[column] == nil {
                keyed[column] = value ?? NSNull()
            }
            return keyed
        }
    }

    static func decodeRustledgerQueryOutput(
        _ data: Data,
        executionTime: TimeInterval
    ) throws -> PluginQueryResult {
        let parsed = try parseRledgerJSON(data)
        guard let columns = parsed.columns else { throw invalidRledgerOutput }

        let rows = try parsed.rows.prefix(PluginRowLimits.emergencyMax).map { row in
            try positionalValues(row, columns: columns).map { value -> PluginCellValue in
                guard let value, !(value is NSNull) else { return .null }
                return .text(rustledgerCellValue(value))
            }
        }

        return PluginQueryResult(
            columns: columns,
            columnTypeNames: Array(repeating: "TEXT", count: columns.count),
            rows: rows,
            rowsAffected: 0,
            executionTime: executionTime,
            isTruncated: parsed.rows.count > rows.count
        )
    }

    // The text `rledger query` prints for each value its JSON output carries: a posting's position is
    // `{units, cost}`, an inventory `{positions}`, tags and links an array, an interval `{count, unit}`.
    static func rustledgerCellValue(_ value: Any) -> String {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "TRUE" : "FALSE"
            }
            return NumberText.text(for: number)
        }
        if let values = value as? [Any] {
            return values.map(rustledgerCellValue).joined(separator: ", ")
        }
        if let object = value as? [String: Any],
           let text = amountText(object) ?? positionText(object) ?? inventoryText(object) ?? intervalText(object) {
            return text
        }
        if let string = NumberText.json(from: value) {
            return string
        }
        return String(describing: value)
    }

    private static func amountText(_ object: [String: Any]) -> String? {
        guard let number = object["number"] as? String,
              let currency = object["currency"] as? String else {
            return nil
        }
        return "\(number) \(currency)"
    }

    private static func positionText(_ object: [String: Any]) -> String? {
        guard let units = (object["units"] as? [String: Any]).flatMap(amountText) else { return nil }
        guard let cost = object["cost"], !(cost is NSNull) else { return units }
        guard let costText = (cost as? [String: Any]).flatMap(amountText) else { return nil }
        return "\(units) {\(costText)}"
    }

    private static func inventoryText(_ object: [String: Any]) -> String? {
        guard let positions = object["positions"] as? [[String: Any]] else { return nil }
        var texts: [String] = []
        for position in positions {
            guard let text = amountText(position) ?? positionText(position) else { return nil }
            texts.append(text)
        }
        return texts.joined(separator: ", ")
    }

    private static func intervalText(_ object: [String: Any]) -> String? {
        guard object.count == 2,
              let count = object["count"] as? Int,
              let unit = object["unit"] as? String else {
            return nil
        }
        return "\(count) \(unit)\(count == 1 || count == -1 ? "" : "s")"
    }
}
