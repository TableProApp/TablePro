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

    static func parse(_ jsonString: String) -> Result<JSONTreeNode, JSONTreeParseError> {
        guard (jsonString as NSString).length <= maxInputLength else {
            return .failure(.tooLarge)
        }
        guard let data = jsonString.data(using: .utf8),
              let jsonObject = try? JSONSerialization.jsonObject(with: data) else {
            return .failure(.invalidJSON)
        }
        var nodeCount = 0
        let root = buildNode(key: nil, keyPath: "$", value: jsonObject, nodeCount: &nodeCount)
        return .success(root)
    }

    private static func buildNode(key: String?, keyPath: String, value: Any, nodeCount: inout Int) -> JSONTreeNode {
        nodeCount += 1

        if let dict = value as? [String: Any] {
            let sortedKeys = dict.keys.sorted()
            var children: [JSONTreeNode] = []
            for k in sortedKeys {
                guard nodeCount < maxNodes else {
                    children.append(truncationNode(remaining: dict.count - children.count))
                    break
                }
                let childPath = keyPath + "." + k
                if let childValue = dict[k] {
                    children.append(buildNode(key: k, keyPath: childPath, value: childValue, nodeCount: &nodeCount))
                }
            }
            return JSONTreeNode(
                key: key, keyPath: keyPath, valueType: .object,
                displayValue: "{\(dict.count) keys}", rawValue: nil, children: children
            )
        }

        if let arr = value as? [Any] {
            var children: [JSONTreeNode] = []
            for (i, item) in arr.enumerated() {
                guard nodeCount < maxNodes else {
                    children.append(truncationNode(remaining: arr.count - i))
                    break
                }
                let childPath = keyPath + "[\(i)]"
                children.append(buildNode(key: "[\(i)]", keyPath: childPath, value: item, nodeCount: &nodeCount))
            }
            return JSONTreeNode(
                key: key, keyPath: keyPath, valueType: .array,
                displayValue: "[\(arr.count) items]", rawValue: nil, children: children
            )
        }

        if let str = value as? String {
            let escaped = str.replacingOccurrences(of: "\"", with: "\\\"")
            let display: String
            let nsLen = (escaped as NSString).length
            if nsLen > 80 {
                let truncated = (escaped as NSString).substring(to: 80)
                display = "\"\(truncated)...\""
            } else {
                display = "\"\(escaped)\""
            }
            return JSONTreeNode(
                key: key, keyPath: keyPath, valueType: .string,
                displayValue: display, rawValue: str, children: []
            )
        }

        if let num = value as? NSNumber {
            if CFBooleanGetTypeID() == CFGetTypeID(num) {
                let boolVal = num.boolValue
                return JSONTreeNode(
                    key: key, keyPath: keyPath, valueType: .boolean,
                    displayValue: boolVal ? "true" : "false",
                    rawValue: boolVal ? "true" : "false", children: []
                )
            }
            let numStr = "\(num)"
            return JSONTreeNode(
                key: key, keyPath: keyPath, valueType: .number,
                displayValue: numStr, rawValue: numStr, children: []
            )
        }

        if value is NSNull {
            return JSONTreeNode(
                key: key, keyPath: keyPath, valueType: .null,
                displayValue: "null", rawValue: nil, children: []
            )
        }

        let fallback = "\(value)"
        return JSONTreeNode(
            key: key, keyPath: keyPath, valueType: .string,
            displayValue: fallback, rawValue: fallback, children: []
        )
    }

    private static func truncationNode(remaining: Int) -> JSONTreeNode {
        JSONTreeNode(
            key: nil, keyPath: "", valueType: .null,
            displayValue: "… (\(remaining) more)", rawValue: nil, children: []
        )
    }
}
