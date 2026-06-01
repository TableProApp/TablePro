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

    var badgeLabel: String {
        switch self {
        case .object: return "obj"
        case .array: return "arr"
        case .string: return "str"
        case .number: return "num"
        case .boolean: return "bool"
        case .null: return "null"
        }
    }

    var color: NSColor {
        switch self {
        case .object, .array: return .systemBlue
        case .string: return .systemRed
        case .number: return .systemPurple
        case .boolean, .null: return .systemOrange
        }
    }
}

internal struct JSONTreeNode: Identifiable {
    let id = UUID()
    let key: String?
    let keyPath: String
    let valueType: JSONValueType
    let displayValue: String
    let rawValue: String?
    let children: [JSONTreeNode]

    var childrenOrNil: [JSONTreeNode]? {
        children.isEmpty ? nil : children
    }
}

internal enum JSONTreeParseError: Error {
    case invalidJSON
    case tooLarge
}

internal enum JSONTreeParser {
    private static let maxNodes = 5_000
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
                display = "\"\((escaped as NSString).substring(to: maxDisplayLength))...\""
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
            key: nil, keyPath: "", valueType: .null,
            displayValue: "… (\(remaining) more)", rawValue: nil, children: []
        )
    }
}
