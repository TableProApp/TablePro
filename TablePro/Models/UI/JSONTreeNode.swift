//
//  JSONTreeNode.swift
//  TablePro
//

import AppKit
import Foundation

internal enum JSONValueType {
    case object
    case array
    case string
    case number
    case boolean
    case null
    case truncated

    var badgeLabel: String {
        switch self {
        case .object: return "obj"
        case .array: return "arr"
        case .string: return "str"
        case .number: return "num"
        case .boolean: return "bool"
        case .null: return "null"
        case .truncated: return "…"
        }
    }

    var color: NSColor {
        switch self {
        case .object, .array: return .systemBlue
        case .string: return .systemRed
        case .number: return .systemPurple
        case .boolean, .null: return .systemOrange
        case .truncated: return .secondaryLabelColor
        }
    }
}

internal struct JSONTreeNode: Identifiable {
    let id: UUID
    let key: String?
    let keyPath: String
    let valueType: JSONValueType
    let displayValue: String
    let rawValue: String?
    let children: [JSONTreeNode]

    init(
        id: UUID = UUID(),
        key: String?,
        keyPath: String,
        valueType: JSONValueType,
        displayValue: String,
        rawValue: String?,
        children: [JSONTreeNode]
    ) {
        self.id = id
        self.key = key
        self.keyPath = keyPath
        self.valueType = valueType
        self.displayValue = displayValue
        self.rawValue = rawValue
        self.children = children
    }

    var childrenOrNil: [JSONTreeNode]? {
        children.isEmpty ? nil : children
    }
}

extension JSONTreeNode: FilterableTreeNode {
    internal var searchableText: String {
        rawValue ?? displayValue
    }

    internal var badgeLabel: String {
        valueType.badgeLabel
    }

    internal var isTruncationMarker: Bool {
        valueType == .truncated
    }

    internal var copyableValue: String {
        switch valueType {
        case .object, .array: return jsonRepresentation
        default: return rawValue ?? displayValue
        }
    }

    internal func replacingChildren(_ children: [JSONTreeNode]) -> JSONTreeNode {
        JSONTreeNode(
            id: id, key: key, keyPath: keyPath, valueType: valueType,
            displayValue: displayValue, rawValue: rawValue, children: children
        )
    }

    private var jsonRepresentation: String {
        switch valueType {
        case .object:
            let members = children.compactMap { child -> String? in
                guard !child.isTruncationMarker, let key = child.key else { return nil }
                return "\(Self.jsonQuoted(key)):\(child.jsonRepresentation)"
            }
            return "{\(members.joined(separator: ","))}"
        case .array:
            let elements = children
                .filter { !$0.isTruncationMarker }
                .map(\.jsonRepresentation)
            return "[\(elements.joined(separator: ","))]"
        case .string:
            return Self.jsonQuoted(rawValue ?? "")
        case .null:
            return "null"
        case .truncated:
            return "null"
        case .number, .boolean:
            return rawValue ?? displayValue
        }
    }

    private static func jsonQuoted(_ value: String) -> String {
        var output = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            default:
                guard scalar.value < 0x20 else {
                    output.unicodeScalars.append(scalar)
                    continue
                }
                output += String(format: "\\u%04x", scalar.value)
            }
        }
        return output + "\""
    }
}

internal enum JSONTreeParseError: Error {
    case invalidJSON
    case tooLarge
}

internal enum JSONTreeParser {
    private static let maxNodes = TreeNodeLimits.maxNodes
    private static let maxInputLength = 100_000
    private static let maxDisplayLength = 300

    static func parse(_ jsonString: String) -> Result<JSONTreeNode, JSONTreeParseError> {
        guard (jsonString as NSString).length <= maxInputLength else {
            return .failure(.tooLarge)
        }
        guard let node = JsonSyntaxParser.parse(jsonString) else {
            return .failure(.invalidJSON)
        }
        var nodeCount = 0
        let root = buildNode(key: nil, keyPath: "$", node: node, nodeCount: &nodeCount)
        return .success(root)
    }

    private static func buildNode(key: String?, keyPath: String, node: JsonSyntaxNode, nodeCount: inout Int) -> JSONTreeNode {
        nodeCount += 1

        switch node {
        case .object(let pairs):
            var children: [JSONTreeNode] = []
            for pair in pairs {
                guard nodeCount < maxNodes else {
                    children.append(truncationNode(remaining: pairs.count - children.count))
                    break
                }
                let decodedKey = JsonSyntaxParser.decodeStringLiteral(pair.key)
                let childPath = keyPath + "." + decodedKey
                children.append(buildNode(key: decodedKey, keyPath: childPath, node: pair.value, nodeCount: &nodeCount))
            }
            return JSONTreeNode(
                key: key, keyPath: keyPath, valueType: .object,
                displayValue: "{\(pairs.count) keys}", rawValue: nil, children: children
            )

        case .array(let elements):
            var children: [JSONTreeNode] = []
            for (index, element) in elements.enumerated() {
                guard nodeCount < maxNodes else {
                    children.append(truncationNode(remaining: elements.count - index))
                    break
                }
                let childPath = keyPath + "[\(index)]"
                children.append(buildNode(key: "[\(index)]", keyPath: childPath, node: element, nodeCount: &nodeCount))
            }
            return JSONTreeNode(
                key: key, keyPath: keyPath, valueType: .array,
                displayValue: "[\(elements.count) items]", rawValue: nil, children: children
            )

        case .string(let raw):
            let decoded = JsonSyntaxParser.decodeStringLiteral(raw)
            let escaped = decoded.replacingOccurrences(of: "\"", with: "\\\"")
            let display: String
            if (escaped as NSString).length > maxDisplayLength {
                display = "\"\((escaped as NSString).substring(to: maxDisplayLength))…\""
            } else {
                display = "\"\(escaped)\""
            }
            return JSONTreeNode(
                key: key, keyPath: keyPath, valueType: .string,
                displayValue: display, rawValue: decoded, children: []
            )

        case .number(let raw):
            return JSONTreeNode(
                key: key, keyPath: keyPath, valueType: .number,
                displayValue: raw, rawValue: raw, children: []
            )

        case .literal(let raw):
            if raw == "null" {
                return JSONTreeNode(
                    key: key, keyPath: keyPath, valueType: .null,
                    displayValue: "null", rawValue: nil, children: []
                )
            }
            return JSONTreeNode(
                key: key, keyPath: keyPath, valueType: .boolean,
                displayValue: raw, rawValue: raw, children: []
            )
        }
    }

    private static func truncationNode(remaining: Int) -> JSONTreeNode {
        JSONTreeNode(
            key: nil, keyPath: "", valueType: .truncated,
            displayValue: "… (\(remaining) more)", rawValue: nil, children: []
        )
    }
}
