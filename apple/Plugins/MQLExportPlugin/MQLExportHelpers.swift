//
//  MQLExportHelpers.swift
//  MQLExportPlugin
//

import Foundation
import TableProJavaScriptText
import TableProNumberFormatting
import TableProPluginKit

enum MQLExportHelpers {
    /// Spelled by the export's own rules rather than `MongoCollectionAccessor`'s, because this
    /// plugin can be released for an app that shipped an older copy of that helper.
    static func collectionAccessor(for name: String) -> String {
        guard JavaScriptText.isPlainIdentifier(name), !MongoCollectionAccessor.isShadowedByDatabaseMember(name) else {
            return "db.getCollection(\(JavaScriptText.stringLiteral(name)))"
        }
        return "db.\(name)"
    }

    static func headerComment(label: String, name: String) -> String {
        JavaScriptText.lineComment("\(label): \(name)")
    }

    static func documentLiteral(_ fields: [(name: String, value: String)]) -> String {
        let members = fields.map { "\(JavaScriptText.stringLiteral($0.name)): \($0.value)" }
        return "  {\(members.joined(separator: ", "))}"
    }

    static func mqlBinaryValue(for data: Data, subtype: UInt8) -> String {
        MongoDBUuidCodec.binaryText(for: MongoDBBinaryValue(data: data, subtype: subtype))
    }

    // The column type is the only record of a cell's BSON type: text in any column that does not name one stays a string.
    static func mqlTextValue(for value: String, columnTypeName: String) -> String {
        typedValue(for: value, columnTypeName: columnTypeName) ?? JavaScriptText.stringLiteral(value)
    }

    private static func typedValue(for value: String, columnTypeName: String) -> String? {
        switch columnTypeName {
        case "ObjectId":
            guard MongoDBObjectId(hex: value).isValid else { return nil }
            return "ObjectId(\(JavaScriptText.stringLiteral(value)))"
        case "TIMESTAMP":
            guard isIso8601(value) else { return nil }
            return "ISODate(\(JavaScriptText.stringLiteral(value)))"
        case "DECIMAL":
            guard NumberText.isJSONNumberLiteral(value) || nonFiniteNumbers.contains(value) else { return nil }
            return "NumberDecimal(\(JavaScriptText.stringLiteral(value)))"
        case "BIGINT":
            guard Int64(value) != nil else { return numberValue(value) }
            return "NumberLong(\(JavaScriptText.stringLiteral(value)))"
        case "FLOAT":
            guard NumberText.isJSONNumber(value), let number = Double(value), readsBackAsInteger(number) else {
                return numberValue(value)
            }
            return "Double(\(value))"
        case "INTEGER":
            return numberValue(value)
        case "BOOLEAN":
            return value == "true" || value == "false" ? value : nil
        case "JSON":
            return containerValue(value)
        default:
            guard uuidColumnTypeNames.contains(columnTypeName),
                  let binary = MongoDBUuidCodec.parseWrapper(value) else { return nil }
            return MongoDBUuidCodec.binaryText(for: binary)
        }
    }

    private static let nonFiniteNumbers: Set<String> = ["NaN", "Infinity", "-Infinity"]

    // The driver names a decoded UUID column by the wrapper its cells are written in.
    private static let uuidColumnTypeNames: Set<String> = Set(
        [MongoDBUuidCodec.standardUuidSubtype, MongoDBUuidCodec.legacyUuidSubtype].flatMap { subtype in
            MongoDBUuidRepresentation.allCases.compactMap {
                MongoDBUuidCodec.wrapperTag(forSubtype: subtype, representation: $0)
            }
        }
    )

    private static func numberValue(_ value: String) -> String? {
        NumberText.isJSONNumber(value) || nonFiniteNumbers.contains(value) ? value : nil
    }

    private static let largestExactInteger: Double = 9_007_199_254_740_991

    private static func readsBackAsInteger(_ number: Double) -> Bool {
        number.rounded(.towardZero) == number && abs(number) <= largestExactInteger
    }

    private static func isIso8601(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value) != nil
    }

    private static func containerValue(_ value: String) -> String? {
        guard (value.hasPrefix("{") && value.hasSuffix("}")) || (value.hasPrefix("[") && value.hasSuffix("]")),
              (try? JSONSerialization.jsonObject(with: Data(value.utf8))) != nil else {
            return nil
        }
        return escapingLineBreaks(inJSON: value)
    }

    /// `JSONSerialization` accepts U+2028, U+2029, DEL and the C1 controls raw inside a string,
    /// and refuses every other character `lineBreakingEscape` answers for outside the whitespace
    /// between tokens. So in JSON it accepted, each such character stands inside a string, where
    /// its escape reads back as the same value.
    private static func escapingLineBreaks(inJSON json: String) -> String {
        var escaped = String.UnicodeScalarView()
        for scalar in json.unicodeScalars {
            if scalar == "\n" || scalar == "\r" || scalar == "\t" {
                escaped.append(scalar)
            } else if let escape = JavaScriptText.lineBreakingEscape(scalar) {
                escaped.append(contentsOf: escape.unicodeScalars)
            } else {
                escaped.append(scalar)
            }
        }
        return String(escaped)
    }
}
