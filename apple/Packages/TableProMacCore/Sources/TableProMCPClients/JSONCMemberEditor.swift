import Foundation

// Edits one member of a JSON or JSONC file as text. A JSONSerialization round trip drops comments, reorders keys and
// re-indents the whole file, so nothing here writes through it; it only checks each edit afterwards.
public enum JSONCMemberEditor {
    public static func member(_ name: String, at keyPath: [String], in text: String) throws -> JSONValue? {
        let bytes = Array(text.utf8)
        guard let root = try JSONCParser.parse(bytes) else { return nil }
        guard let container = try walk(root, keyPath: keyPath) else { return nil }
        return try uniqueMember(name, in: container, path: keyPath)?.value.value
    }

    public static func upserting(_ name: String, value: JSONValue, at keyPath: [String], in text: String) throws -> String {
        let bytes = Array(text.utf8)
        let result: String
        if let root = try JSONCParser.parse(bytes) {
            let document = Document(bytes: bytes, root: root)
            result = try document.upserting(name, value: value, at: keyPath)
        } else {
            result = startingDocument(name, value: value, at: keyPath, after: text)
        }
        try verify(old: text, new: result, keyPath: keyPath, name: name, expected: value)
        return result
    }

    // Update: `entry` is rendered from `template`, which says which members are TablePro's to rewrite (MCPEntryUpdate).
    public static func updating(
        _ name: String,
        entry: JSONValue,
        template: JSONValue,
        at keyPath: [String],
        in text: String
    ) throws -> String {
        switch MCPEntryUpdate.plan(existing: try member(name, at: keyPath, in: text), entry: entry, template: template) {
        case .replace(let value): try upserting(name, value: value, at: keyPath, in: text)
        case .merge(let value): try merging(name, value: value, at: keyPath, in: text)
        }
    }

    // Rewrites only the members `value` names inside an existing object entry, so keys the user added to it stay.
    public static func merging(_ name: String, value: JSONValue, at keyPath: [String], in text: String) throws -> String {
        guard case .object(let wanted) = value,
              let existing = try member(name, at: keyPath, in: text),
              existing.objectMembers != nil else {
            return try upserting(name, value: value, at: keyPath, in: text)
        }
        var result = text
        for part in wanted where existing[part.key] != part.value {
            result = try merging(part.key, value: part.value, at: keyPath + [name], in: result)
        }
        guard try member(name, at: keyPath, in: result) == existing.merging(value) else {
            throw MCPConfigEditError.verificationFailed
        }
        return result
    }

    public static func removing(_ name: String, at keyPath: [String], in text: String) throws -> String {
        let bytes = Array(text.utf8)
        guard let root = try JSONCParser.parse(bytes) else { return text }
        let document = Document(bytes: bytes, root: root)
        let result = try document.removing(name, at: keyPath)
        guard result != text else { return text }
        try verify(old: text, new: result, keyPath: keyPath, name: name, expected: nil)
        return result
    }

    static func walk(_ root: JSONCNode, keyPath: [String]) throws -> JSONCNode? {
        guard root.members != nil else { throw MCPConfigEditError.notAnObject([]) }
        var container = root
        var walked: [String] = []
        for key in keyPath {
            walked.append(key)
            guard let member = try uniqueMember(key, in: container, path: Array(walked.dropLast())) else { return nil }
            guard member.value.members != nil else { throw MCPConfigEditError.notAnObject(walked) }
            container = member.value
        }
        return container
    }

    static func uniqueMember(_ key: String, in container: JSONCNode, path: [String]) throws -> JSONCMember? {
        let matches = (container.members ?? []).filter { $0.key == key }
        guard matches.count <= 1 else { throw MCPConfigEditError.duplicateKey(path + [key]) }
        return matches.first
    }

    private static func startingDocument(_ name: String, value: JSONValue, at keyPath: [String], after text: String) -> String {
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let style = JSONTextStyle(indentUnit: "  ", newline: newline, multiline: true, spaced: true)
        let body = style.render(JSONValue.nested(keyPath + [name], leaf: value), indent: "") + newline
        guard !text.allSatisfy(\.isWhitespace) else { return body }
        let separator = text.utf8.last == 0x0A ? "" : newline
        return text + separator + body
    }

    private static func verify(old: String, new: String, keyPath: [String], name: String, expected: JSONValue?) throws {
        let before = try foundationObject(old)
        let after = try foundationObject(new)
        let wanted = replacing(name, in: before, at: keyPath, with: expected?.foundationObject)
        guard NSDictionary(dictionary: wanted).isEqual(to: after) else {
            throw MCPConfigEditError.verificationFailed
        }
    }

    private static func foundationObject(_ text: String) throws -> [String: Any] {
        let bytes = Array(text.utf8)
        guard try JSONCParser.parse(bytes) != nil else { return [:] }
        let data = Data(JSONCParser.replacingLoneSurrogateEscapes(bytes))
        let object = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed])
        guard let dictionary = object as? [String: Any] else { throw MCPConfigEditError.invalidSyntax }
        return dictionary
    }

    private static func replacing(_ name: String, in dictionary: [String: Any], at keyPath: [String], with value: Any?) -> [String: Any] {
        var result = dictionary
        guard let key = keyPath.first else {
            result[name] = value
            return result
        }
        if let child = dictionary[key] as? [String: Any] {
            result[key] = replacing(name, in: child, at: Array(keyPath.dropFirst()), with: value)
        } else if value != nil {
            result[key] = replacing(name, in: [:], at: Array(keyPath.dropFirst()), with: value)
        }
        return result
    }
}

private struct Document {
    let bytes: [UInt8]
    let root: JSONCNode
    let newline: String
    let indentUnit: String
    let spaced: Bool
    let isMultiline: Bool

    init(bytes: [UInt8], root: JSONCNode) {
        self.bytes = bytes
        self.root = root
        newline = Self.contains(bytes, [0x0D, 0x0A]) ? "\r\n" : "\n"
        // An empty root is a fresh file, so it is laid out like a written one rather than kept on one line.
        isMultiline = bytes[root.range].contains(0x0A) || root.members?.isEmpty == true
        var unit: String?
        var spacedSeparator: Bool?
        Self.survey(root, bytes: bytes, unit: &unit, spaced: &spacedSeparator)
        indentUnit = unit ?? "  "
        spaced = spacedSeparator ?? true
    }

    func upserting(_ name: String, value: JSONValue, at keyPath: [String]) throws -> String {
        guard root.members != nil else { throw MCPConfigEditError.notAnObject([]) }
        var container = root
        for (position, key) in keyPath.enumerated() {
            let walked = Array(keyPath.prefix(position))
            guard let member = try JSONCMemberEditor.uniqueMember(key, in: container, path: walked) else {
                let rest = Array(keyPath.dropFirst(position + 1)) + [name]
                return apply(inserting(key, value: JSONValue.nested(rest, leaf: value), into: container))
            }
            guard member.value.members != nil else { throw MCPConfigEditError.notAnObject(walked + [key]) }
            container = member.value
        }
        guard let existing = try JSONCMemberEditor.uniqueMember(name, in: container, path: keyPath) else {
            return apply(inserting(name, value: value, into: container))
        }
        let style = textStyle(multiline: spansLines(container))
        let rendered = style.render(value, indent: lineIndent(at: existing.keyRange.lowerBound))
        return apply([Splice(range: existing.value.range, text: rendered)])
    }

    func removing(_ name: String, at keyPath: [String]) throws -> String {
        guard let container = try JSONCMemberEditor.walk(root, keyPath: keyPath),
              let target = try JSONCMemberEditor.uniqueMember(name, in: container, path: keyPath),
              let members = container.members,
              let position = members.firstIndex(where: { $0.keyRange == target.keyRange }) else {
            return utf8Text(bytes)
        }
        let previous = position > 0 ? members[position - 1] : nil
        var splices: [Splice] = []
        let memberEnd = target.commaOffset.map { $0 + 1 } ?? target.value.range.upperBound
        if spansLines(container), isFirstOnLine(target.keyRange.lowerBound), let lineEnd = endOfLine(after: memberEnd) {
            splices.append(Splice(range: lineStart(of: target.keyRange.lowerBound)..<afterNewline(lineEnd), text: ""))
            if target.commaOffset == nil, let comma = previous?.commaOffset {
                splices.append(Splice(range: comma..<(comma + 1), text: ""))
            }
        } else if let comma = target.commaOffset {
            splices.append(Splice(range: target.keyRange.lowerBound..<skipSpaces(from: comma + 1), text: ""))
        } else if let comma = previous?.commaOffset {
            splices.append(Splice(range: comma..<target.value.range.upperBound, text: ""))
        } else {
            splices.append(Splice(range: target.keyRange.lowerBound..<target.value.range.upperBound, text: ""))
        }
        if members.count == 1 {
            return collapsingEmptyContainer(apply(splices), keyPath: keyPath)
        }
        return apply(splices)
    }

    private func collapsingEmptyContainer(_ text: String, keyPath: [String]) -> String {
        let edited = Array(text.utf8)
        guard let root = try? JSONCParser.parse(edited),
              let container = try? JSONCMemberEditor.walk(root, keyPath: keyPath),
              container.members?.isEmpty == true else {
            return text
        }
        let interior = (container.range.lowerBound + 1)..<(container.range.upperBound - 1)
        guard !interior.isEmpty, edited[interior].allSatisfy(Self.isWhitespace) else { return text }
        var result = edited
        result.removeSubrange(interior)
        return utf8Text(result)
    }

    private func inserting(_ name: String, value: JSONValue, into container: JSONCNode) -> [Splice] {
        let members = container.members ?? []
        let open = container.range.lowerBound
        let close = container.range.upperBound - 1
        let multiline = spansLines(container) || (members.isEmpty && isMultiline)
        let style = textStyle(multiline: multiline)
        let colon = spaced ? ": " : ":"

        guard let last = members.last else {
            guard multiline else {
                let text = JSONTextStyle.quoted(name) + colon + style.render(value, indent: "")
                return [Splice(range: (open + 1)..<close, text: text)]
            }
            let outer = lineIndent(at: open)
            let indent = outer + indentUnit
            let member = indent + JSONTextStyle.quoted(name) + colon + style.render(value, indent: indent)
            let interior = (open + 1)..<close
            if bytes[interior].allSatisfy(Self.isWhitespace) {
                return [Splice(range: interior, text: newline + member + newline + outer)]
            }
            if isFirstOnLine(close), lineStart(of: close) > lineStart(of: open) {
                let start = lineStart(of: close)
                return [Splice(range: start..<start, text: member + newline)]
            }
            return [Splice(range: close..<close, text: newline + member + newline + outer)]
        }

        let trailingComma = last.commaOffset != nil
        let anchor = last.commaOffset.map { $0 + 1 } ?? last.value.range.upperBound
        guard multiline else {
            let text = (trailingComma ? (spaced ? " " : "") : (spaced ? ", " : ","))
                + JSONTextStyle.quoted(name) + colon + style.render(value, indent: "") + (trailingComma ? "," : "")
            return [Splice(range: anchor..<anchor, text: text)]
        }
        let indent = isFirstOnLine(last.keyRange.lowerBound)
            ? lineIndent(at: last.keyRange.lowerBound)
            : lineIndent(at: open) + indentUnit
        let member = newline + indent + JSONTextStyle.quoted(name) + colon + style.render(value, indent: indent)
            + (trailingComma ? "," : "")
        let insertion = endOfLine(after: anchor) ?? anchor
        var splices = [Splice(range: insertion..<insertion, text: member)]
        if !trailingComma {
            let end = last.value.range.upperBound
            splices.append(Splice(range: end..<end, text: ","))
        }
        return splices
    }

    private func textStyle(multiline: Bool) -> JSONTextStyle {
        JSONTextStyle(indentUnit: indentUnit, newline: newline, multiline: multiline, spaced: spaced)
    }

    private struct Splice {
        let range: Range<Int>
        let text: String
    }

    private func apply(_ splices: [Splice]) -> String {
        var result = bytes
        for splice in splices.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            result.replaceSubrange(splice.range, with: Array(splice.text.utf8))
        }
        return utf8Text(result)
    }

    private func spansLines(_ node: JSONCNode) -> Bool {
        bytes[node.range].contains(0x0A)
    }

    private func lineStart(of offset: Int) -> Int {
        var index = offset
        while index > 0, bytes[index - 1] != 0x0A {
            index -= 1
        }
        return index
    }

    private func lineIndent(at offset: Int) -> String {
        let start = lineStart(of: offset)
        var end = start
        while end < bytes.count, bytes[end] == 0x20 || bytes[end] == 0x09 {
            end += 1
        }
        return utf8Text(bytes[start..<end])
    }

    private func isFirstOnLine(_ offset: Int) -> Bool {
        bytes[lineStart(of: offset)..<offset].allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0xEF || $0 == 0xBB || $0 == 0xBF }
    }

    private func skipSpaces(from offset: Int) -> Int {
        var index = offset
        while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 {
            index += 1
        }
        return index
    }

    // The offset of the line break after `offset`, past spaces and comments on the same line; nil when a token follows.
    private func endOfLine(after offset: Int) -> Int? {
        var index = offset
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09:
                index += 1
            case 0x0D where index + 1 < bytes.count && bytes[index + 1] == 0x0A:
                return index
            case 0x0A:
                return index
            case UInt8(ascii: "/") where index + 1 < bytes.count && bytes[index + 1] == UInt8(ascii: "/"):
                while index < bytes.count, bytes[index] != 0x0A {
                    index += 1
                }
                if index > offset, bytes[index - 1] == 0x0D {
                    return index - 1
                }
                return index
            case UInt8(ascii: "/") where index + 1 < bytes.count && bytes[index + 1] == UInt8(ascii: "*"):
                var end = index + 2
                while end + 1 < bytes.count, !(bytes[end] == UInt8(ascii: "*") && bytes[end + 1] == UInt8(ascii: "/")) {
                    if bytes[end] == 0x0A { return nil }
                    end += 1
                }
                index = end + 2
            default:
                return nil
            }
        }
        return bytes.count
    }

    private func afterNewline(_ offset: Int) -> Int {
        if offset < bytes.count, bytes[offset] == 0x0D {
            return min(offset + 2, bytes.count)
        }
        return min(offset + 1, bytes.count)
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func contains(_ bytes: [UInt8], _ pair: [UInt8]) -> Bool {
        zip(bytes, bytes.dropFirst()).contains { $0.0 == pair[0] && $0.1 == pair[1] }
    }

    // The indent unit is the step from a container's line to its first member's line, from the first container that has one.
    private static func survey(_ node: JSONCNode, bytes: [UInt8], unit: inout String?, spaced: inout Bool?) {
        switch node.content {
        case .object(let members):
            if let first = members.first {
                if spaced == nil {
                    spaced = bytes[first.keyRange.upperBound..<first.value.range.lowerBound].contains { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A }
                }
                if unit == nil {
                    unit = step(from: node.range.lowerBound, to: first.keyRange.lowerBound, bytes: bytes)
                }
            }
            for member in members where unit == nil || spaced == nil {
                survey(member.value, bytes: bytes, unit: &unit, spaced: &spaced)
            }
        case .array(let items):
            if unit == nil, let first = items.first {
                unit = step(from: node.range.lowerBound, to: first.range.lowerBound, bytes: bytes)
            }
            for item in items where unit == nil || spaced == nil {
                survey(item, bytes: bytes, unit: &unit, spaced: &spaced)
            }
        case .scalar:
            break
        }
    }

    private static func step(from open: Int, to child: Int, bytes: [UInt8]) -> String? {
        func indent(_ offset: Int) -> (start: Int, text: [UInt8])? {
            var start = offset
            while start > 0, bytes[start - 1] != 0x0A {
                start -= 1
            }
            var end = start
            while end < offset, bytes[end] == 0x20 || bytes[end] == 0x09 {
                end += 1
            }
            guard end == offset else { return nil }
            return (start, Array(bytes[start..<end]))
        }
        guard let childIndent = indent(child) else { return nil }
        var openStart = open
        while openStart > 0, bytes[openStart - 1] != 0x0A {
            openStart -= 1
        }
        guard openStart != childIndent.start else { return nil }
        var openEnd = openStart
        while openEnd < bytes.count, bytes[openEnd] == 0x20 || bytes[openEnd] == 0x09 {
            openEnd += 1
        }
        let outer = Array(bytes[openStart..<openEnd])
        guard childIndent.text.count > outer.count, childIndent.text.starts(with: outer) else { return nil }
        return utf8Text(childIndent.text[outer.count...])
    }
}
