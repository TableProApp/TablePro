import Foundation
import TableProPluginKit

/// Moves attribute values into grid cells and edited cells back into attribute values.
///
/// A cell carries text, bytes or nothing, never a type, so an edit is decoded against a template:
/// the attribute's current value when the item has one, otherwise the column's type. That is what
/// keeps `02134` a String, a String Set a set and a nested Binary binary when a map is edited as
/// plain JSON.
enum DynamoDBCellCodec {
    static func cell(for value: DynamoDBAttributeValue?) -> PluginCellValue {
        guard let value else { return .null }
        switch value {
        case .string(let text):
            return .text(text)
        case .number(let text):
            return .text(text)
        case .bool(let flag):
            return .text(flag ? "true" : "false")
        case .null:
            return .null
        case .binary(let data):
            return .bytes(data)
        case .list, .map, .stringSet, .numberSet, .binarySet:
            return .text(plainJSON(value).serialized())
        }
    }

    /// The JSON a person reads and edits: no type envelopes, map keys and set members in a fixed
    /// order so the same value always renders as the same text.
    static func plainJSON(_ value: DynamoDBAttributeValue) -> DynamoDBJSON {
        switch value {
        case .string(let text):
            return .string(text)
        case .number(let text):
            return .number(jsonNumberText(text))
        case .binary(let data):
            return .string(data.base64EncodedString())
        case .bool(let flag):
            return .bool(flag)
        case .null:
            return .null
        case .list(let items):
            return .array(items.map(plainJSON))
        case .map(let entries):
            return .object(entries.mapValues(plainJSON))
        case .stringSet(let members):
            return .array(members.sorted().map(DynamoDBJSON.string))
        case .numberSet(let members):
            return .array(
                members.sorted { DynamoDBNumber.compare($0, $1) == .orderedAscending }
                    .map { .number(jsonNumberText($0)) }
            )
        case .binarySet(let members):
            return .array(members.map { $0.base64EncodedString() }.sorted().map(DynamoDBJSON.string))
        }
    }

    /// Decodes an edited cell. Nil means the attribute is removed.
    static func decode(
        _ cell: PluginCellValue,
        template: DynamoDBAttributeValue?,
        columnType: DynamoDBAttributeType?,
        attribute: String
    ) throws -> DynamoDBAttributeValue? {
        switch cell {
        case .null:
            return nil
        case .bytes(let data):
            return .binary(data)
        case .text(let text):
            let targetType = template?.type ?? columnType
            guard let targetType else { return inferred(from: text) }
            return try decode(text: text, as: targetType, template: template, attribute: attribute)
        }
    }

    static func decode(
        text: String,
        as type: DynamoDBAttributeType,
        template: DynamoDBAttributeValue?,
        attribute: String
    ) throws -> DynamoDBAttributeValue {
        switch type {
        case .string:
            return .string(text)
        case .number:
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard DynamoDBNumber.isValid(trimmed) else {
                throw DynamoDBError.invalidValue(
                    attribute: attribute,
                    reason: String(format: String(localized: "\"%@\" is not a DynamoDB number"), text)
                )
            }
            return .number(trimmed)
        case .boolean:
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "1": return .bool(true)
            case "false", "0": return .bool(false)
            default:
                throw DynamoDBError.invalidValue(
                    attribute: attribute,
                    reason: String(format: String(localized: "\"%@\" is not true or false"), text)
                )
            }
        case .null:
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.caseInsensitiveCompare("null") == .orderedSame {
                return .null
            }
            return inferred(from: text)
        case .binary:
            guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw DynamoDBError.invalidValue(
                    attribute: attribute, reason: String(localized: "A Binary value must be base64")
                )
            }
            return .binary(data)
        case .list, .map, .stringSet, .numberSet, .binarySet:
            let json: DynamoDBJSON
            do {
                json = try DynamoDBJSON.parse(text)
            } catch {
                throw DynamoDBError.invalidValue(
                    attribute: attribute,
                    reason: String(format: String(localized: "A %@ value must be JSON: %@"),
                                   type.displayName, error.localizedDescription)
                )
            }
            return try value(fromPlainJSON: json, template: template ?? emptyTemplate(for: type), attribute: attribute)
        }
    }

    static func value(
        fromPlainJSON json: DynamoDBJSON,
        template: DynamoDBAttributeValue?,
        attribute: String
    ) throws -> DynamoDBAttributeValue {
        switch json {
        case .object(let entries):
            var templates: [String: DynamoDBAttributeValue] = [:]
            if case .map(let existing) = template { templates = existing }
            var converted: [String: DynamoDBAttributeValue] = [:]
            for (key, element) in entries {
                converted[key] = try value(fromPlainJSON: element, template: templates[key], attribute: attribute)
            }
            return .map(converted)
        case .array(let elements):
            return try arrayValue(elements, template: template, attribute: attribute)
        case .string(let text):
            if case .binary = template, let data = Data(base64Encoded: text) {
                return .binary(data)
            }
            return .string(text)
        case .number(let text):
            guard DynamoDBNumber.isValid(text) else {
                throw DynamoDBError.invalidValue(
                    attribute: attribute,
                    reason: String(format: String(localized: "\"%@\" is not a DynamoDB number"), text)
                )
            }
            return .number(text)
        case .bool(let flag):
            return .bool(flag)
        case .null:
            return .null
        }
    }

    private static func arrayValue(
        _ elements: [DynamoDBJSON],
        template: DynamoDBAttributeValue?,
        attribute: String
    ) throws -> DynamoDBAttributeValue {
        switch template {
        case .stringSet:
            let members = elements.compactMap(\.stringValue)
            if members.count == elements.count {
                return .stringSet(try validatedSet(members, attribute: attribute) { Array($0.utf8) == Array($1.utf8) })
            }
        case .numberSet:
            let members = elements.compactMap { $0.numberText ?? $0.stringValue }
            if members.count == elements.count, members.allSatisfy(DynamoDBNumber.isValid) {
                return .numberSet(try validatedSet(members, attribute: attribute, sameMember: DynamoDBNumber.areEqual))
            }
        case .binarySet:
            let members = elements.compactMap { $0.stringValue.flatMap { Data(base64Encoded: $0) } }
            if members.count == elements.count {
                return .binarySet(try validatedSet(members, attribute: attribute, sameMember: ==))
            }
        default:
            break
        }
        var itemTemplates: [DynamoDBAttributeValue] = []
        if case .list(let existing) = template { itemTemplates = existing }
        return .list(try elements.enumerated().map { index, element in
            let elementTemplate = index < itemTemplates.count ? itemTemplates[index] : nil
            return try value(fromPlainJSON: element, template: elementTemplate, attribute: attribute)
        })
    }

    private static func validatedSet<Member>(
        _ members: [Member],
        attribute: String,
        sameMember: (Member, Member) -> Bool
    ) throws -> [Member] {
        guard !members.isEmpty else {
            throw DynamoDBError.invalidValue(
                attribute: attribute, reason: String(localized: "A set can't be empty. Clear the cell to remove it.")
            )
        }
        for (index, member) in members.enumerated() where members[..<index].contains(where: { sameMember($0, member) }) {
            throw DynamoDBError.invalidValue(
                attribute: attribute, reason: String(localized: "A set can't contain the same value twice")
            )
        }
        return members
    }

    /// Text arriving for an attribute with no type anywhere to copy: an object or array becomes a
    /// Map or a List, everything else a String. A Number is never guessed from text that looks like
    /// one, because `02134` read as a Number is `2134`.
    static func inferred(from text: String) -> DynamoDBAttributeValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[",
              let json = try? DynamoDBJSON.parse(trimmed),
              let converted = try? value(fromPlainJSON: json, template: nil, attribute: "")
        else { return .string(text) }
        return converted
    }

    private static func emptyTemplate(for type: DynamoDBAttributeType) -> DynamoDBAttributeValue? {
        switch type {
        case .stringSet: return .stringSet([])
        case .numberSet: return .numberSet([])
        case .binarySet: return .binarySet([])
        case .map: return .map([:])
        case .list: return .list([])
        default: return nil
        }
    }

    /// DynamoDB accepts `+5`, `.5`, `5.` and `007`, none of which is a JSON number.
    static func jsonNumberText(_ text: String) -> String {
        var body = text.trimmingCharacters(in: .whitespaces)
        var sign = ""
        if let first = body.first, first == "+" || first == "-" {
            sign = first == "-" ? "-" : ""
            body.removeFirst()
        }
        var mantissa = body
        var exponent = ""
        if let marker = body.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = String(body[..<marker])
            exponent = String(body[marker...])
        }
        var integer = mantissa
        var fraction = ""
        if let dot = mantissa.firstIndex(of: ".") {
            integer = String(mantissa[..<dot])
            fraction = String(mantissa[mantissa.index(after: dot)...])
        }
        integer = String(integer.drop { $0 == "0" })
        if integer.isEmpty { integer = "0" }
        let fractionText = fraction.isEmpty ? "" : ".\(fraction)"
        return sign + integer + fractionText + exponent
    }
}
