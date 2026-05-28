//
//  PhpTreeNode.swift
//  TablePro
//

import AppKit
import Foundation

internal enum PhpNodeType {
    case null
    case bool
    case int
    case float
    case string
    case array
    case object
    case serializable
    case reference
    case unsupported
    case truncated

    var badgeLabel: String {
        switch self {
        case .null: return "null"
        case .bool: return "bool"
        case .int: return "int"
        case .float: return "float"
        case .string: return "str"
        case .array: return "arr"
        case .object: return "obj"
        case .serializable: return "ser"
        case .reference: return "ref"
        case .unsupported: return "?"
        case .truncated: return "..."
        }
    }

    var color: NSColor {
        switch self {
        case .array, .object: return .systemBlue
        case .string: return .systemRed
        case .int, .float: return .systemPurple
        case .bool, .null: return .systemOrange
        case .serializable: return .systemTeal
        case .reference: return .systemGray
        case .unsupported, .truncated: return .secondaryLabelColor
        }
    }
}

internal struct PhpTreeNode: Identifiable {
    let id: UUID
    let key: String?
    let keyPath: String
    let nodeType: PhpNodeType
    let displayValue: String
    let visibilityBadge: String?
    let children: [PhpTreeNode]

    init(
        id: UUID = UUID(),
        key: String?,
        keyPath: String,
        nodeType: PhpNodeType,
        displayValue: String,
        visibilityBadge: String? = nil,
        children: [PhpTreeNode] = []
    ) {
        self.id = id
        self.key = key
        self.keyPath = keyPath
        self.nodeType = nodeType
        self.displayValue = displayValue
        self.visibilityBadge = visibilityBadge
        self.children = children
    }

    var childrenOrNil: [PhpTreeNode]? {
        children.isEmpty ? nil : children
    }
}

internal enum PhpTreeBuilder {
    static let maxNodes = 5_000

    static func build(from phpValue: PhpValue) -> PhpTreeNode {
        var nodeCount = 0
        return makeNode(key: nil, keyPath: "$", value: phpValue, nodeCount: &nodeCount)
    }

    private static func makeNode(
        key: String?,
        keyPath: String,
        value: PhpValue,
        nodeCount: inout Int,
        visibility: PhpVisibility = .publicVisibility
    ) -> PhpTreeNode {
        nodeCount += 1
        let badge = visibilityBadge(for: visibility)

        switch value {
        case .null:
            return PhpTreeNode(
                key: key, keyPath: keyPath, nodeType: .null,
                displayValue: "null", visibilityBadge: badge
            )

        case .bool(let flag):
            return PhpTreeNode(
                key: key, keyPath: keyPath, nodeType: .bool,
                displayValue: flag ? "true" : "false", visibilityBadge: badge
            )

        case .int(let intValue):
            return PhpTreeNode(
                key: key, keyPath: keyPath, nodeType: .int,
                displayValue: String(intValue), visibilityBadge: badge
            )

        case .float(let doubleValue):
            return PhpTreeNode(
                key: key, keyPath: keyPath, nodeType: .float,
                displayValue: floatDisplay(doubleValue), visibilityBadge: badge
            )

        case .string(let stringValue):
            return PhpTreeNode(
                key: key, keyPath: keyPath, nodeType: .string,
                displayValue: stringDisplay(stringValue), visibilityBadge: badge
            )

        case .array(let entries):
            var children: [PhpTreeNode] = []
            children.reserveCapacity(entries.count)
            for entry in entries {
                if nodeCount >= maxNodes {
                    children.append(truncationNode(remaining: entries.count - children.count))
                    break
                }
                let childKey = arrayKeyDisplay(entry.key)
                let childPath = arrayChildPath(parent: keyPath, key: entry.key)
                children.append(
                    makeNode(key: childKey, keyPath: childPath, value: entry.value, nodeCount: &nodeCount)
                )
            }
            return PhpTreeNode(
                key: key, keyPath: keyPath, nodeType: .array,
                displayValue: "[\(entries.count) items]",
                visibilityBadge: badge, children: children
            )

        case .object(let className, let properties):
            var children: [PhpTreeNode] = []
            children.reserveCapacity(properties.count)
            for property in properties {
                if nodeCount >= maxNodes {
                    children.append(truncationNode(remaining: properties.count - children.count))
                    break
                }
                let childPath = "\(keyPath).\(property.name)"
                children.append(
                    makeNode(
                        key: property.name,
                        keyPath: childPath,
                        value: property.value,
                        nodeCount: &nodeCount,
                        visibility: property.visibility
                    )
                )
            }
            return PhpTreeNode(
                key: key, keyPath: keyPath, nodeType: .object,
                displayValue: "\(className) {\(properties.count) properties}",
                visibilityBadge: badge, children: children
            )

        case .serializable(let className, let rawPayload):
            return PhpTreeNode(
                key: key, keyPath: keyPath, nodeType: .serializable,
                displayValue: serializableDisplay(className: className, payload: rawPayload),
                visibilityBadge: badge
            )

        case .reference(let identifier):
            return PhpTreeNode(
                key: key, keyPath: keyPath, nodeType: .reference,
                displayValue: "→ #\(identifier)", visibilityBadge: badge
            )

        case .unsupported(let token):
            return PhpTreeNode(
                key: key, keyPath: keyPath, nodeType: .unsupported,
                displayValue: String(format: String(localized: "Unsupported token: %@"), token),
                visibilityBadge: badge
            )

        case .depthExceeded:
            return PhpTreeNode(
                key: key, keyPath: keyPath, nodeType: .truncated,
                displayValue: String(localized: "Maximum depth reached"),
                visibilityBadge: badge
            )

        case .tooLarge:
            return PhpTreeNode(
                key: key, keyPath: keyPath, nodeType: .truncated,
                displayValue: String(localized: "Value too large to parse"),
                visibilityBadge: badge
            )
        }
    }

    private static func truncationNode(remaining: Int) -> PhpTreeNode {
        PhpTreeNode(
            key: nil, keyPath: "", nodeType: .truncated,
            displayValue: "… (\(remaining) more)"
        )
    }

    private static func arrayKeyDisplay(_ key: PhpValue) -> String {
        switch key {
        case .int(let intValue): return "[\(intValue)]"
        case .string(let stringValue): return stringValue
        default: return "?"
        }
    }

    private static func arrayChildPath(parent: String, key: PhpValue) -> String {
        switch key {
        case .int(let intValue): return "\(parent)[\(intValue)]"
        case .string(let stringValue): return "\(parent).\(stringValue)"
        default: return parent
        }
    }

    private static func visibilityBadge(for visibility: PhpVisibility) -> String? {
        switch visibility {
        case .publicVisibility: return nil
        case .protectedVisibility: return String(localized: "protected")
        case .privateVisibility(let className):
            return String(format: String(localized: "private (%@)"), className)
        }
    }

    private static func stringDisplay(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
        let length = (escaped as NSString).length
        if length > 80 {
            let head = (escaped as NSString).substring(to: 80)
            return "\"\(head)...\""
        }
        return "\"\(escaped)\""
    }

    private static func floatDisplay(_ value: Double) -> String {
        if value.isNaN { return "NAN" }
        if value.isInfinite { return value > 0 ? "INF" : "-INF" }
        return String(value)
    }

    private static func serializableDisplay(className: String, payload: String) -> String {
        let length = (payload as NSString).length
        if length > 80 {
            let head = (payload as NSString).substring(to: 80)
            return "\(className) \(head)..."
        }
        return "\(className) \(payload)"
    }
}
