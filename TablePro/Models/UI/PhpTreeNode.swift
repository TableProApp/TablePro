//
//  PhpTreeNode.swift
//  TablePro
//

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
        case .truncated: return "…"
        }
    }

    var tone: TreeValueTone {
        switch self {
        case .array, .object: return .container
        case .string: return .string
        case .int, .float: return .number
        case .bool, .null: return .literal
        case .serializable: return .serialized
        case .reference: return .reference
        case .unsupported, .truncated: return .muted
        }
    }
}

internal struct PhpTreeNode: Identifiable {
    let id: UUID
    let key: String?
    let keyPath: String
    let path: TreeNodePath
    let nodeType: PhpNodeType
    let displayValue: String
    let isDisplayCut: Bool
    let rawValue: String?
    let className: String?
    let visibilityBadge: String?
    let children: [PhpTreeNode]

    init(
        id: UUID = UUID(),
        key: String?,
        keyPath: String,
        path: TreeNodePath,
        nodeType: PhpNodeType,
        displayValue: String,
        isDisplayCut: Bool = false,
        rawValue: String? = nil,
        className: String? = nil,
        visibilityBadge: String? = nil,
        children: [PhpTreeNode] = []
    ) {
        self.id = id
        self.key = key
        self.keyPath = keyPath
        self.path = path
        self.nodeType = nodeType
        self.displayValue = displayValue
        self.isDisplayCut = isDisplayCut
        self.rawValue = rawValue
        self.className = className
        self.visibilityBadge = visibilityBadge
        self.children = children
    }

    var childrenOrNil: [PhpTreeNode]? {
        children.isEmpty ? nil : children
    }
}

extension PhpTreeNode: FilterableTreeNode {
    /// An integer key is stored in the value, unlike a JSON array index, so it stays searchable.
    internal var searchableKey: String? {
        key
    }

    /// A class name is data. A count and the cut marker are text the tree made up.
    internal var searchableText: String {
        switch nodeType {
        case .array, .truncated: return ""
        case .object: return className ?? ""
        case .serializable: return [className, rawValue].compactMap { $0 }.joined(separator: " ")
        case .null, .bool, .int, .float, .string, .reference, .unsupported: return rawValue ?? displayValue
        }
    }

    internal var badgeLabel: String {
        nodeType.badgeLabel
    }

    internal var isTruncationMarker: Bool {
        nodeType == .truncated
    }

    internal var copyableValue: String {
        rawValue ?? displayValue
    }

    internal var rowContent: TreeRowContent {
        TreeRowContent(
            key: key,
            value: displayValue,
            string: nodeType == .string ? rawValue : nil,
            isCut: isDisplayCut,
            tone: nodeType.tone,
            typeBadge: nodeType.badgeLabel,
            visibilityBadge: visibilityBadge
        )
    }

    internal func replacingChildren(_ children: [PhpTreeNode]) -> PhpTreeNode {
        PhpTreeNode(
            id: id, key: key, keyPath: keyPath, path: path, nodeType: nodeType,
            displayValue: displayValue, isDisplayCut: isDisplayCut, rawValue: rawValue,
            className: className, visibilityBadge: visibilityBadge, children: children
        )
    }
}

internal enum PhpTreeBuilder {
    static let maxNodes = TreeNodeLimits.maxNodes
    private static let maxDisplayLength = 80

    static func build(from phpValue: PhpValue, formats: TreeSummaryFormats = .localized) -> PhpTreeNode {
        var nodeCount = 0
        return makeNode(key: nil, keyPath: "$", path: .root, value: phpValue, formats: formats, nodeCount: &nodeCount)
    }

    private static func makeNode(
        key: String?,
        keyPath: String,
        path: TreeNodePath,
        value: PhpValue,
        formats: TreeSummaryFormats,
        nodeCount: inout Int,
        visibility: PhpVisibility = .publicVisibility
    ) -> PhpTreeNode {
        nodeCount += 1
        let badge = visibilityBadge(for: visibility)

        switch value {
        case .null:
            return PhpTreeNode(
                key: key, keyPath: keyPath, path: path, nodeType: .null,
                displayValue: "null", visibilityBadge: badge
            )

        case .bool(let flag):
            return PhpTreeNode(
                key: key, keyPath: keyPath, path: path, nodeType: .bool,
                displayValue: flag ? "true" : "false", visibilityBadge: badge
            )

        case .int(let intValue):
            return PhpTreeNode(
                key: key, keyPath: keyPath, path: path, nodeType: .int,
                displayValue: String(intValue), visibilityBadge: badge
            )

        case .float(let doubleValue):
            return PhpTreeNode(
                key: key, keyPath: keyPath, path: path, nodeType: .float,
                displayValue: floatDisplay(doubleValue), visibilityBadge: badge
            )

        case .string(let stringValue):
            let display = TreeDisplayText.quoted(stringValue, limit: maxDisplayLength)
            return PhpTreeNode(
                key: key, keyPath: keyPath, path: path, nodeType: .string,
                displayValue: display.text, isDisplayCut: display.isCut,
                rawValue: stringValue, visibilityBadge: badge
            )

        case .array(let entries):
            var children: [PhpTreeNode] = []
            children.reserveCapacity(entries.count)
            var siblings = TreeSiblingCounter()
            for entry in entries {
                if nodeCount >= maxNodes {
                    children.append(truncationNode(remaining: entries.count - children.count, parent: path))
                    break
                }
                children.append(
                    makeNode(
                        key: arrayKeyDisplay(entry.key),
                        keyPath: arrayChildPath(parent: keyPath, key: entry.key),
                        path: path.appending(arrayKeyComponent(entry.key, siblings: &siblings)),
                        value: entry.value,
                        formats: formats,
                        nodeCount: &nodeCount
                    )
                )
            }
            return PhpTreeNode(
                key: key, keyPath: keyPath, path: path, nodeType: .array,
                displayValue: "[\(formats.items.text(entries.count))]",
                visibilityBadge: badge, children: children
            )

        case .object(let className, let properties):
            var children: [PhpTreeNode] = []
            children.reserveCapacity(properties.count)
            var siblings = TreeSiblingCounter()
            for property in properties {
                if nodeCount >= maxNodes {
                    children.append(truncationNode(remaining: properties.count - children.count, parent: path))
                    break
                }
                children.append(
                    makeNode(
                        key: property.name,
                        keyPath: "\(keyPath).\(TreeKeyPathSyntax.member(property.name))",
                        path: path.appending(siblings.key(property.name)),
                        value: property.value,
                        formats: formats,
                        nodeCount: &nodeCount,
                        visibility: property.visibility
                    )
                )
            }
            return PhpTreeNode(
                key: key, keyPath: keyPath, path: path, nodeType: .object,
                displayValue: "\(className) {\(formats.properties.text(properties.count))}",
                className: className, visibilityBadge: badge, children: children
            )

        case .serializable(let className, let rawPayload):
            return PhpTreeNode(
                key: key, keyPath: keyPath, path: path, nodeType: .serializable,
                displayValue: serializableDisplay(className: className, payload: rawPayload),
                rawValue: rawPayload, className: className, visibilityBadge: badge
            )

        case .reference(let identifier):
            return PhpTreeNode(
                key: key, keyPath: keyPath, path: path, nodeType: .reference,
                displayValue: "→ #\(identifier)", visibilityBadge: badge
            )

        case .unsupported(let token):
            return PhpTreeNode(
                key: key, keyPath: keyPath, path: path, nodeType: .unsupported,
                displayValue: String(format: String(localized: "Unsupported token: %@"), token),
                visibilityBadge: badge
            )

        case .depthExceeded:
            return PhpTreeNode(
                key: key, keyPath: keyPath, path: path, nodeType: .truncated,
                displayValue: String(localized: "Maximum depth reached"),
                visibilityBadge: badge
            )

        case .tooLarge:
            return PhpTreeNode(
                key: key, keyPath: keyPath, path: path, nodeType: .truncated,
                displayValue: String(localized: "Value too large to parse"),
                visibilityBadge: badge
            )
        }
    }

    private static func truncationNode(remaining: Int, parent: TreeNodePath) -> PhpTreeNode {
        PhpTreeNode(
            key: nil, keyPath: "", path: parent.appending(.truncationMarker), nodeType: .truncated,
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
        case .string(let stringValue): return "\(parent).\(TreeKeyPathSyntax.member(stringValue))"
        default: return parent
        }
    }

    private static func arrayKeyComponent(_ key: PhpValue, siblings: inout TreeSiblingCounter) -> TreeNodePath.Component {
        switch key {
        case .int(let intValue): return siblings.integerKey(intValue)
        case .string(let stringValue): return siblings.key(stringValue)
        default: return siblings.key(arrayKeyDisplay(key))
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

    private static func floatDisplay(_ value: Double) -> String {
        if value.isNaN { return "NAN" }
        if value.isInfinite { return value > 0 ? "INF" : "-INF" }
        return String(value)
    }

    private static func serializableDisplay(className: String, payload: String) -> String {
        let head = TreeDisplayText.cut(payload, limit: maxDisplayLength)
        return "\(className) \(head.text)\(head.isCut ? "…" : "")"
    }
}
