//
//  ProtobufTreeNode.swift
//  TablePro
//

import Foundation

// Without a schema the key is the field number and the badge the wire type; a schema gives name and declared type.
internal struct ProtobufTreeNode: Identifiable {
    internal enum Kind: Equatable {
        case message
        case group
        case varint
        case fixed64
        case fixed32
        case string
        case bytes
        case truncated

        init(_ value: ProtobufFieldValue) {
            switch value {
            case .message: self = .message
            case .group: self = .group
            case .varint: self = .varint
            case .fixed64: self = .fixed64
            case .fixed32: self = .fixed32
            case .string: self = .string
            case .bytes: self = .bytes
            case .truncated: self = .truncated
            }
        }

        var badgeLabel: String {
            switch self {
            case .message, .string, .bytes: return "len"
            case .group: return "group"
            case .varint: return "varint"
            case .fixed64: return "i64"
            case .fixed32: return "i32"
            case .truncated: return "…"
            }
        }

        var tone: TreeValueTone {
            switch self {
            case .message, .group: return .container
            case .string: return .string
            case .varint, .fixed64, .fixed32: return .number
            case .bytes: return .serialized
            case .truncated: return .muted
            }
        }
    }

    let id: UUID
    let key: String?
    let keyPath: String
    let path: TreeNodePath
    let kind: Kind
    let displayValue: String
    let isDisplayCut: Bool
    let rawValue: String?
    let members: [ProtobufField]
    let typeBadge: String?
    let typedMembers: [ProtobufTypedField]
    let children: [ProtobufTreeNode]

    init(
        id: UUID = UUID(),
        key: String?,
        keyPath: String,
        path: TreeNodePath,
        kind: Kind,
        displayValue: String,
        isDisplayCut: Bool = false,
        rawValue: String? = nil,
        members: [ProtobufField] = [],
        typeBadge: String? = nil,
        typedMembers: [ProtobufTypedField] = [],
        children: [ProtobufTreeNode] = []
    ) {
        self.id = id
        self.key = key
        self.keyPath = keyPath
        self.path = path
        self.kind = kind
        self.displayValue = displayValue
        self.isDisplayCut = isDisplayCut
        self.rawValue = rawValue
        self.members = members
        self.typeBadge = typeBadge
        self.typedMembers = typedMembers
        self.children = children
    }
}

extension ProtobufTreeNode: FilterableTreeNode {
    internal var searchableKey: String? {
        key
    }

    internal var searchableText: String {
        switch kind {
        case .message, .group, .truncated: return ""
        case .varint, .fixed64, .fixed32, .string, .bytes: return rawValue ?? displayValue
        }
    }

    internal var badgeLabel: String {
        typeBadge ?? kind.badgeLabel
    }

    internal var isTruncationMarker: Bool {
        kind == .truncated
    }

    internal var copyableValue: String {
        switch kind {
        case .message, .group:
            guard typedMembers.isEmpty else { return ProtobufSchemaTextWriter.text(typedMembers, multiLine: false) }
            return ProtobufTextWriter.text(members, multiLine: false)
        case .varint, .fixed64, .fixed32, .string, .bytes, .truncated:
            return rawValue ?? displayValue
        }
    }

    internal var copyableValueIncludesDescendants: Bool {
        switch kind {
        case .message, .group: return true
        case .varint, .fixed64, .fixed32, .string, .bytes, .truncated: return false
        }
    }

    internal var rowContent: TreeRowContent {
        TreeRowContent(
            key: key,
            value: displayValue,
            string: kind == .string ? rawValue : nil,
            isCut: isDisplayCut,
            tone: kind.tone,
            typeBadge: badgeLabel,
            visibilityBadge: nil
        )
    }

    internal func replacingChildren(_ children: [ProtobufTreeNode]) -> ProtobufTreeNode {
        ProtobufTreeNode(
            id: id, key: key, keyPath: keyPath, path: path, kind: kind,
            displayValue: displayValue, isDisplayCut: isDisplayCut, rawValue: rawValue, members: members,
            typeBadge: typeBadge, typedMembers: typedMembers, children: children
        )
    }
}
