//
//  ProtobufRendering.swift
//  TablePro
//

import Foundation

// `protoc --decode_raw` output, except that UTF-8 text keeps its characters instead of octal escapes.
internal enum ProtobufTextWriter {
    static func text(_ fields: [ProtobufField], multiLine: Bool, limit: Int = .max) -> String {
        var output = ""
        write(fields, into: &output, multiLine: multiLine, depth: 0, limit: limit)
        return multiLine ? output : output.trimmingCharacters(in: .whitespaces)
    }

    static func scalarText(_ value: ProtobufFieldValue, limit: Int = .max) -> String? {
        switch value {
        case .varint(let number): return String(number)
        case .fixed64(let number): return String(format: "0x%016llx", number)
        case .fixed32(let number): return String(format: "0x%08x", number)
        case .string(let text): return quoted(text.scalarPrefix(limit))
        case .bytes(let data): return quoted(data.prefix(limit))
        case .message, .group, .truncated: return nil
        }
    }

    private static func write(
        _ fields: [ProtobufField],
        into output: inout String,
        multiLine: Bool,
        depth: Int,
        limit: Int
    ) {
        let indent = multiLine ? String(repeating: "  ", count: depth) : ""
        let separator = multiLine ? "\n" : " "
        for field in fields {
            let room = limit - output.utf8.count
            guard room > 0 else { return }
            switch field.value {
            case .message(let members), .group(let members):
                output += "\(indent)\(field.number) {\(separator)"
                write(members, into: &output, multiLine: multiLine, depth: depth + 1, limit: limit)
                output += "\(indent)}\(separator)"
            case .truncated:
                output += "\(indent)…\(separator)"
            case .varint, .fixed64, .fixed32, .string, .bytes:
                output += "\(indent)\(field.number): \(scalarText(field.value, limit: room) ?? "")\(separator)"
            }
        }
    }

    private static func quoted(_ text: String) -> String {
        var output = "\""
        for scalar in text.unicodeScalars {
            if scalar.value < 0x80 {
                appendEscaped(UInt8(scalar.value), to: &output)
            } else {
                output.unicodeScalars.append(scalar)
            }
        }
        return output + "\""
    }

    private static func quoted(_ data: Data) -> String {
        var output = "\""
        for byte in data {
            appendEscaped(byte, to: &output)
        }
        return output + "\""
    }

    // Protobuf's CEscape.
    private static func appendEscaped(_ byte: UInt8, to output: inout String) {
        switch byte {
        case 0x0A: output += "\\n"
        case 0x0D: output += "\\r"
        case 0x09: output += "\\t"
        case 0x22: output += "\\\""
        case 0x27: output += "\\'"
        case 0x5C: output += "\\\\"
        case 0x20...0x7E: output.unicodeScalars.append(Unicode.Scalar(byte))
        default: output += String(format: "\\%03o", byte)
        }
    }
}

internal enum ProtobufTreeBuilder {
    private static let maxDisplayLength = 300

    static func build(from fields: [ProtobufField], formats: TreeSummaryFormats = .localized) -> ProtobufTreeNode {
        var nodeCount = 0
        let children = makeChildren(fields, keyPath: nil, path: .root, formats: formats, nodeCount: &nodeCount)
        return ProtobufTreeNode(
            key: nil, keyPath: "", path: .root, kind: .message,
            displayValue: "{\(formats.fields.text(fields.count))}", members: fields, children: children
        )
    }

    private static func makeChildren(
        _ fields: [ProtobufField],
        keyPath: String?,
        path: TreeNodePath,
        formats: TreeSummaryFormats,
        nodeCount: inout Int
    ) -> [ProtobufTreeNode] {
        var children: [ProtobufTreeNode] = []
        var siblings = TreeSiblingCounter()
        for field in fields where field.value != .truncated {
            guard nodeCount < TreeNodeLimits.maxNodes else {
                children.append(ProtobufTreeNode(
                    key: nil, keyPath: "", path: path.appending(.truncationMarker), kind: .truncated,
                    displayValue: "… (\(fields.count - children.count) more)"
                ))
                break
            }
            let name = String(field.number)
            children.append(node(
                key: name,
                keyPath: keyPath.map { "\($0).\(name)" } ?? name,
                path: path.appending(siblings.key(name)),
                value: field.value,
                formats: formats,
                nodeCount: &nodeCount
            ))
        }
        return children
    }

    private static func node(
        key: String,
        keyPath: String,
        path: TreeNodePath,
        value: ProtobufFieldValue,
        formats: TreeSummaryFormats,
        nodeCount: inout Int
    ) -> ProtobufTreeNode {
        nodeCount += 1
        switch value {
        case .message(let members), .group(let members):
            let children = makeChildren(members, keyPath: keyPath, path: path, formats: formats, nodeCount: &nodeCount)
            return ProtobufTreeNode(
                key: key, keyPath: keyPath, path: path, kind: value.isGroup ? .group : .message,
                displayValue: "{\(formats.fields.text(members.count))}", members: members, children: children
            )
        case .string(let text):
            let display = TreeDisplayText.quoted(text, limit: maxDisplayLength)
            return ProtobufTreeNode(
                key: key, keyPath: keyPath, path: path, kind: .string,
                displayValue: display.text, isDisplayCut: display.isCut, rawValue: text
            )
        case .varint, .fixed64, .fixed32, .bytes, .truncated:
            let text = ProtobufTextWriter.scalarText(value) ?? ""
            let display = TreeDisplayText.cut(text, limit: maxDisplayLength)
            return ProtobufTreeNode(
                key: key, keyPath: keyPath, path: path, kind: ProtobufTreeNode.Kind(value),
                displayValue: display.isCut ? display.text + "…" : display.text,
                isDisplayCut: display.isCut, rawValue: text
            )
        }
    }
}

private extension ProtobufFieldValue {
    var isGroup: Bool {
        if case .group = self { return true }
        return false
    }
}
