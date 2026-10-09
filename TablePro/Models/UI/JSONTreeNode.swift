//
//  JSONTreeNode.swift
//  TablePro
//

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

    var tone: TreeValueTone {
        switch self {
        case .object, .array: return .container
        case .string: return .string
        case .number: return .number
        case .boolean, .null: return .literal
        case .truncated: return .muted
        }
    }
}

internal struct JSONTreeNode: Identifiable {
    let id: UUID
    let key: String?
    let keyPath: String
    let path: TreeNodePath
    let valueType: JSONValueType
    let displayValue: String
    let isDisplayCut: Bool
    let rawValue: String?
    let children: [JSONTreeNode]

    init(
        id: UUID = UUID(),
        key: String?,
        keyPath: String,
        path: TreeNodePath,
        valueType: JSONValueType,
        displayValue: String,
        isDisplayCut: Bool = false,
        rawValue: String?,
        children: [JSONTreeNode]
    ) {
        self.id = id
        self.key = key
        self.keyPath = keyPath
        self.path = path
        self.valueType = valueType
        self.displayValue = displayValue
        self.isDisplayCut = isDisplayCut
        self.rawValue = rawValue
        self.children = children
    }

    var childrenOrNil: [JSONTreeNode]? {
        children.isEmpty ? nil : children
    }
}

extension JSONTreeNode: FilterableTreeNode {
    /// An array element's key is the `[n]` the tree printed, not text from the document.
    internal var searchableKey: String? {
        guard case .key = path.lastComponent else { return nil }
        return key
    }

    /// Empty where the row shows a count or the cut marker, which the document does not contain.
    internal var searchableText: String {
        switch valueType {
        case .object, .array, .truncated: return ""
        case .string, .number, .boolean, .null: return rawValue ?? displayValue
        }
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

    internal var rowContent: TreeRowContent {
        TreeRowContent(
            key: key,
            value: displayValue,
            string: valueType == .string ? rawValue : nil,
            isCut: isDisplayCut,
            tone: valueType.tone,
            typeBadge: valueType.badgeLabel,
            visibilityBadge: nil
        )
    }

    internal func replacingChildren(_ children: [JSONTreeNode]) -> JSONTreeNode {
        JSONTreeNode(
            id: id, key: key, keyPath: keyPath, path: path, valueType: valueType,
            displayValue: displayValue, isDisplayCut: isDisplayCut, rawValue: rawValue, children: children
        )
    }

    private var jsonRepresentation: String {
        switch valueType {
        case .object:
            let members = children.compactMap { child -> String? in
                guard !child.isTruncationMarker, let key = child.key else { return nil }
                return "\(TreeDisplayText.jsonQuoted(key)):\(child.jsonRepresentation)"
            }
            return "{\(members.joined(separator: ","))}"
        case .array:
            let elements = children
                .filter { !$0.isTruncationMarker }
                .map(\.jsonRepresentation)
            return "[\(elements.joined(separator: ","))]"
        case .string:
            return TreeDisplayText.jsonQuoted(rawValue ?? "")
        case .null:
            return "null"
        case .truncated:
            return "null"
        case .number, .boolean:
            return rawValue ?? displayValue
        }
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

    static func parse(
        _ jsonString: String,
        formats: TreeSummaryFormats = .localized
    ) -> Result<JSONTreeNode, JSONTreeParseError> {
        guard (jsonString as NSString).length <= maxInputLength else {
            return .failure(.tooLarge)
        }
        guard let node = JsonSyntaxParser.parse(jsonString) else {
            return .failure(.invalidJSON)
        }
        var nodeCount = 0
        let root = buildNode(key: nil, keyPath: "$", path: .root, node: node, formats: formats, nodeCount: &nodeCount)
        return .success(root)
    }

    private static func buildNode(
        key: String?,
        keyPath: String,
        path: TreeNodePath,
        node: JsonSyntaxNode,
        formats: TreeSummaryFormats,
        nodeCount: inout Int
    ) -> JSONTreeNode {
        nodeCount += 1

        switch node {
        case .object(let pairs):
            var children: [JSONTreeNode] = []
            var siblings = TreeSiblingCounter()
            for pair in pairs {
                guard nodeCount < maxNodes else {
                    children.append(truncationNode(remaining: pairs.count - children.count, parent: path))
                    break
                }
                let decodedKey = JsonSyntaxParser.decodeStringLiteral(pair.key)
                children.append(
                    buildNode(
                        key: decodedKey,
                        keyPath: keyPath + "." + TreeKeyPathSyntax.member(decodedKey),
                        path: path.appending(siblings.key(decodedKey)),
                        node: pair.value,
                        formats: formats,
                        nodeCount: &nodeCount
                    )
                )
            }
            return JSONTreeNode(
                key: key, keyPath: keyPath, path: path, valueType: .object,
                displayValue: "{\(formats.keys.text(pairs.count))}", rawValue: nil, children: children
            )

        case .array(let elements):
            var children: [JSONTreeNode] = []
            for (index, element) in elements.enumerated() {
                guard nodeCount < maxNodes else {
                    children.append(truncationNode(remaining: elements.count - index, parent: path))
                    break
                }
                children.append(
                    buildNode(
                        key: "[\(index)]",
                        keyPath: keyPath + "[\(index)]",
                        path: path.appending(.index(index)),
                        node: element,
                        formats: formats,
                        nodeCount: &nodeCount
                    )
                )
            }
            return JSONTreeNode(
                key: key, keyPath: keyPath, path: path, valueType: .array,
                displayValue: "[\(formats.items.text(elements.count))]", rawValue: nil, children: children
            )

        case .string(let raw):
            let decoded = JsonSyntaxParser.decodeStringLiteral(raw)
            let display = TreeDisplayText.quoted(decoded, limit: maxDisplayLength)
            return JSONTreeNode(
                key: key, keyPath: keyPath, path: path, valueType: .string,
                displayValue: display.text, isDisplayCut: display.isCut, rawValue: decoded, children: []
            )

        case .number(let raw):
            return JSONTreeNode(
                key: key, keyPath: keyPath, path: path, valueType: .number,
                displayValue: raw, rawValue: raw, children: []
            )

        case .literal(let raw):
            if raw == "null" {
                return JSONTreeNode(
                    key: key, keyPath: keyPath, path: path, valueType: .null,
                    displayValue: "null", rawValue: nil, children: []
                )
            }
            return JSONTreeNode(
                key: key, keyPath: keyPath, path: path, valueType: .boolean,
                displayValue: raw, rawValue: raw, children: []
            )
        }
    }

    private static func truncationNode(remaining: Int, parent: TreeNodePath) -> JSONTreeNode {
        JSONTreeNode(
            key: nil, keyPath: "", path: parent.appending(.truncationMarker), valueType: .truncated,
            displayValue: "… (\(remaining) more)", rawValue: nil, children: []
        )
    }
}
