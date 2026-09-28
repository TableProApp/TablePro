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

    /// A mongosh script inserts a string wherever it sees one, so a typed scalar has to be
    /// written as its constructor. The column type is the only surviving record of the type.
    static func mqlTextValue(for value: String, columnTypeName: String) -> String {
        switch columnTypeName {
        case "ObjectId":
            let objectId = MongoDBObjectId(hex: value)
            guard objectId.isValid else { break }
            return "ObjectId(\(JavaScriptText.stringLiteral(value)))"
        case "TIMESTAMP":
            guard isIso8601(value) else { break }
            return "ISODate(\(JavaScriptText.stringLiteral(value)))"
        case "DECIMAL":
            guard NumberText.isJSONNumberLiteral(value) else { break }
            return "NumberDecimal(\(JavaScriptText.stringLiteral(value)))"
        default:
            break
        }
        return mqlJsonValue(for: value)
    }

    private static func isIso8601(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value) != nil
    }

    static func mqlJsonValue(for value: String) -> String {
        if value == "true" || value == "false" {
            return value
        }
        if value == "null" {
            return "null"
        }
        if NumberText.isJSONNumber(value) {
            return value
        }
        if let binary = MongoDBUuidCodec.parseWrapper(value) {
            return MongoDBUuidCodec.binaryText(for: binary)
        }
        if (value.hasPrefix("{") && value.hasSuffix("}")) ||
            (value.hasPrefix("[") && value.hasSuffix("]")) {
            if let data = value.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: data)) != nil {
                return escapingLineBreaks(inJSON: value)
            }
        }
        return JavaScriptText.stringLiteral(value)
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
