//
//  MessagePackRendering.swift
//  TablePro
//

import Foundation

// Types JSON lacks are written as strings in the form the tree shows them.
internal enum MessagePackTextWriter {
    static func json(_ value: MessagePackValue, pretty: Bool, limit: Int = .max) -> String {
        var output = ""
        write(value, into: &output, pretty: pretty, depth: 0, limit: limit)
        return output
    }

    static func keyText(_ key: MessagePackValue) -> String {
        if case .string(let text) = key { return text }
        return scalarText(key) ?? json(key, pretty: false)
    }

    static func scalarText(_ value: MessagePackValue, limit: Int = .max) -> String? {
        switch value {
        case .null: return "null"
        case .bool(let flag): return flag ? "true" : "false"
        case .int(let number): return String(number)
        case .uint(let number): return String(number)
        case .float(let number): return numberText(Double(number), description: number.description)
        case .double(let number): return numberText(number, description: number.description)
        case .binary(let data): return "0x" + data.uppercaseHex(maxBytes: limit / 2)
        case .ext(let type, let data): return "ext(\(type)) 0x" + data.uppercaseHex(maxBytes: limit / 2)
        case .timestamp(let seconds, let nanoseconds): return RFC3339Timestamp.format(seconds: seconds, nanoseconds: nanoseconds)
        case .string, .array, .map, .truncated: return nil
        }
    }

    private static func numberText(_ value: Double, description: String) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value > 0 ? "Infinity" : "-Infinity" }
        return description
    }

    private static func write(
        _ value: MessagePackValue,
        into output: inout String,
        pretty: Bool,
        depth: Int,
        limit: Int
    ) {
        let room = limit - output.utf8.count
        guard room > 0 else { return }
        switch value {
        case .string(let text):
            output += TreeDisplayText.jsonQuoted(text.scalarPrefix(room))
        case .binary, .ext, .timestamp:
            output += TreeDisplayText.jsonQuoted(scalarText(value, limit: room) ?? "")
        case .null, .bool, .int, .uint, .float, .double:
            output += scalarText(value) ?? ""
        case .truncated:
            output += "…"
        case .array(let items):
            guard !items.isEmpty else {
                output += "[]"
                return
            }
            output += "["
            for (index, item) in items.enumerated() {
                guard output.utf8.count < limit else { return }
                if index > 0 { output += "," }
                newline(into: &output, pretty: pretty, depth: depth + 1)
                write(item, into: &output, pretty: pretty, depth: depth + 1, limit: limit)
            }
            newline(into: &output, pretty: pretty, depth: depth)
            output += "]"
        case .map(let pairs):
            guard !pairs.isEmpty else {
                output += "{}"
                return
            }
            output += "{"
            for (index, pair) in pairs.enumerated() {
                guard output.utf8.count < limit else { return }
                if index > 0 { output += "," }
                newline(into: &output, pretty: pretty, depth: depth + 1)
                if pair.key == .truncated {
                    output += "…"
                    continue
                }
                output += TreeDisplayText.jsonQuoted(keyText(pair.key).scalarPrefix(limit - output.utf8.count))
                output += pretty ? ": " : ":"
                write(pair.value, into: &output, pretty: pretty, depth: depth + 1, limit: limit)
            }
            newline(into: &output, pretty: pretty, depth: depth)
            output += "}"
        }
    }

    private static func newline(into output: inout String, pretty: Bool, depth: Int) {
        guard pretty else { return }
        output += "\n" + String(repeating: "  ", count: depth)
    }
}

internal enum MessagePackTreeBuilder {
    private static let maxDisplayLength = 300

    static func build(from value: MessagePackValue, formats: TreeSummaryFormats = .localized) -> JSONTreeNode {
        var nodeCount = 0
        return node(key: nil, keyPath: "$", path: .root, value: value, formats: formats, nodeCount: &nodeCount)
    }

    private static func node(
        key: String?,
        keyPath: String,
        path: TreeNodePath,
        value: MessagePackValue,
        formats: TreeSummaryFormats,
        nodeCount: inout Int
    ) -> JSONTreeNode {
        nodeCount += 1
        switch value {
        case .map(let pairs):
            var children: [JSONTreeNode] = []
            var siblings = TreeSiblingCounter()
            for pair in pairs where pair.key != .truncated {
                guard nodeCount < TreeNodeLimits.maxNodes else {
                    children.append(truncationNode(remaining: pairs.count - children.count, parent: path))
                    break
                }
                let name = MessagePackTextWriter.keyText(pair.key)
                children.append(node(
                    key: name,
                    keyPath: keyPath + "." + TreeKeyPathSyntax.member(name),
                    path: path.appending(siblings.key(name)),
                    value: pair.value,
                    formats: formats,
                    nodeCount: &nodeCount
                ))
            }
            return JSONTreeNode(
                key: key, keyPath: keyPath, path: path, valueType: .object,
                displayValue: "{\(formats.keys.text(pairs.count))}", rawValue: nil, children: children
            )
        case .array(let items):
            var children: [JSONTreeNode] = []
            for (index, item) in items.enumerated() where item != .truncated {
                guard nodeCount < TreeNodeLimits.maxNodes else {
                    children.append(truncationNode(remaining: items.count - index, parent: path))
                    break
                }
                children.append(node(
                    key: "[\(index)]",
                    keyPath: keyPath + "[\(index)]",
                    path: path.appending(.index(index)),
                    value: item,
                    formats: formats,
                    nodeCount: &nodeCount
                ))
            }
            return JSONTreeNode(
                key: key, keyPath: keyPath, path: path, valueType: .array,
                displayValue: "[\(formats.items.text(items.count))]", rawValue: nil, children: children
            )
        case .string(let text):
            let display = TreeDisplayText.quoted(text, limit: maxDisplayLength)
            return JSONTreeNode(
                key: key, keyPath: keyPath, path: path, valueType: .string,
                displayValue: display.text, isDisplayCut: display.isCut, rawValue: text, children: []
            )
        case .null:
            return leaf(key: key, keyPath: keyPath, path: path, type: .null, text: "null", rawValue: nil)
        case .bool:
            return leaf(key: key, keyPath: keyPath, path: path, type: .boolean, value: value)
        case .int, .uint, .float, .double:
            return leaf(key: key, keyPath: keyPath, path: path, type: .number, value: value)
        case .binary:
            return leaf(key: key, keyPath: keyPath, path: path, type: .binary, value: value)
        case .ext:
            return leaf(key: key, keyPath: keyPath, path: path, type: .extension, value: value)
        case .timestamp:
            return leaf(key: key, keyPath: keyPath, path: path, type: .timestamp, value: value)
        case .truncated:
            return truncationNode(remaining: 1, parent: path.parent ?? .root)
        }
    }

    private static func leaf(
        key: String?,
        keyPath: String,
        path: TreeNodePath,
        type: JSONValueType,
        value: MessagePackValue
    ) -> JSONTreeNode {
        let text = MessagePackTextWriter.scalarText(value) ?? ""
        return leaf(key: key, keyPath: keyPath, path: path, type: type, text: text, rawValue: text)
    }

    private static func leaf(
        key: String?,
        keyPath: String,
        path: TreeNodePath,
        type: JSONValueType,
        text: String,
        rawValue: String?
    ) -> JSONTreeNode {
        let display = TreeDisplayText.cut(text, limit: maxDisplayLength)
        return JSONTreeNode(
            key: key, keyPath: keyPath, path: path, valueType: type,
            displayValue: display.isCut ? display.text + "…" : display.text,
            isDisplayCut: display.isCut, rawValue: rawValue, children: []
        )
    }

    private static func truncationNode(remaining: Int, parent: TreeNodePath) -> JSONTreeNode {
        JSONTreeNode(
            key: nil, keyPath: "", path: parent.appending(.truncationMarker), valueType: .truncated,
            displayValue: "… (\(remaining) more)", rawValue: nil, children: []
        )
    }
}

// Hinnant's civil-from-days, since Date and its formatters lose the nanoseconds and most of the Int64 range.
internal enum RFC3339Timestamp {
    static func format(seconds: Int64, nanoseconds: UInt32) -> String {
        let (days, secondOfDay) = floorDivide(seconds, 86_400)
        let civil = civilDate(fromDays: days)
        let hour = secondOfDay / 3_600
        let minute = secondOfDay % 3_600 / 60
        let second = secondOfDay % 60
        let year = civil.year < 0 || civil.year > 9_999
            ? String(format: "%+05lld", civil.year)
            : String(format: "%04lld", civil.year)
        var text = year + String(format: "-%02lld-%02lldT%02lld:%02lld:%02lld", civil.month, civil.day, hour, minute, second)
        if nanoseconds > 0 {
            var fraction = String(format: "%09u", nanoseconds)
            while fraction.hasSuffix("0") { fraction.removeLast() }
            text += "." + fraction
        }
        return text + "Z"
    }

    private static func floorDivide(_ value: Int64, _ divisor: Int64) -> (Int64, Int64) {
        let quotient = value / divisor
        let remainder = value % divisor
        return remainder < 0 ? (quotient - 1, remainder + divisor) : (quotient, remainder)
    }

    private static func civilDate(fromDays days: Int64) -> (year: Int64, month: Int64, day: Int64) {
        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return (year, month, day)
    }
}
