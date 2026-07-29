//
//  JsonReindenter.swift
//  TablePro
//

import Foundation

internal enum JsonReindenter {
    private static let maxLength = 500_000
    private static let defaultIndent = "  "

    static func reindentIfValid(_ source: String, indent: String = defaultIndent) -> String? {
        guard (source as NSString).length <= maxLength else { return nil }
        guard let node = JsonSyntaxParser.parse(source) else { return nil }
        var output = ""
        writePretty(node, into: &output, indent: indent, depth: 0)
        return output
    }

    static func reindent(_ source: String, indent: String = defaultIndent) -> String {
        reindentIfValid(source, indent: indent) ?? source
    }

    static func normalize(_ source: String) -> String {
        guard (source as NSString).length <= maxLength else { return source }
        guard let node = JsonSyntaxParser.parse(source) else { return source }
        var output = ""
        writeCompact(node, into: &output)
        return output
    }

    private static func writePretty(_ node: JsonSyntaxNode, into output: inout String, indent: String, depth: Int) {
        switch node {
        case .string(let raw), .number(let raw), .literal(let raw):
            output += raw
        case .object(let pairs):
            guard !pairs.isEmpty else {
                output += "{}"
                return
            }
            output += "{\n"
            let childPad = String(repeating: indent, count: depth + 1)
            for (offset, pair) in pairs.enumerated() {
                output += childPad + pair.key + ": "
                writePretty(pair.value, into: &output, indent: indent, depth: depth + 1)
                output += offset == pairs.count - 1 ? "\n" : ",\n"
            }
            output += String(repeating: indent, count: depth) + "}"
        case .array(let elements):
            guard !elements.isEmpty else {
                output += "[]"
                return
            }
            output += "[\n"
            let childPad = String(repeating: indent, count: depth + 1)
            for (offset, element) in elements.enumerated() {
                output += childPad
                writePretty(element, into: &output, indent: indent, depth: depth + 1)
                output += offset == elements.count - 1 ? "\n" : ",\n"
            }
            output += String(repeating: indent, count: depth) + "]"
        }
    }

    private static func writeCompact(_ node: JsonSyntaxNode, into output: inout String) {
        switch node {
        case .string(let raw), .number(let raw), .literal(let raw):
            output += raw
        case .object(let pairs):
            output += "{"
            for (offset, pair) in pairs.enumerated() {
                output += pair.key + ":"
                writeCompact(pair.value, into: &output)
                if offset != pairs.count - 1 { output += "," }
            }
            output += "}"
        case .array(let elements):
            output += "["
            for (offset, element) in elements.enumerated() {
                writeCompact(element, into: &output)
                if offset != elements.count - 1 { output += "," }
            }
            output += "]"
        }
    }
}
