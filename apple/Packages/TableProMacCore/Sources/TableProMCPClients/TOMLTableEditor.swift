import Foundation

// Reads and splices one `[<keyPath>.<name>]` table (and its subtables) of a TOML file such as Codex's config.toml.
// A server defined any other way is refused, since rewriting it would mean rewriting someone else's layout.
public enum TOMLTableEditor {
    public static func member(_ name: String, at keyPath: [String], in text: String) throws -> JSONValue? {
        let file = try File(text: text, target: keyPath + [name])
        guard file.layout.table != nil || !file.layout.subtables.isEmpty else { return nil }
        return try file.serverValue()
    }

    public static func upserting(_ name: String, value: JSONValue, at keyPath: [String], in text: String) throws -> String {
        let target = keyPath + [name]
        let file = try File(text: text, target: target)
        guard !file.layout.containerIsValue else { throw MCPConfigEditError.unsupportedShape }
        let block = try renderBlock(header: target, value: value, newline: file.newline)

        var splices: [(range: Range<Int>, text: String)] = file.layout.subtables.map { (range: file.removalRange(of: $0), text: "") }
        if let table = file.layout.table {
            let range = file.blockRange(of: table)
            let endsWithoutNewline = range.upperBound == file.bytes.count && file.bytes.last != 0x0A
            splices.append((range: range, text: endsWithoutNewline ? String(block.dropLast()) : block))
        }
        var result = file.applying(splices)
        if file.layout.table == nil {
            result = appending(block, to: result, newline: file.newline)
        }
        guard try member(name, at: keyPath, in: result) == value else { throw MCPConfigEditError.verificationFailed }
        return result
    }

    // Update: `entry` is rendered from `template`, which says which keys are TablePro's to rewrite (MCPEntryUpdate).
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

    // Rewrites only the keys `value` names, so the user's other keys, comments and subtables stay; an unchanged key is untouched.
    public static func merging(_ name: String, value: JSONValue, at keyPath: [String], in text: String) throws -> String {
        let target = keyPath + [name]
        let file = try File(text: text, target: target)
        guard !file.layout.containerIsValue else { throw MCPConfigEditError.unsupportedShape }
        guard case .object(let wanted) = value, file.layout.table != nil || !file.layout.subtables.isEmpty else {
            return try upserting(name, value: value, at: keyPath, in: text)
        }
        let existing = try file.serverValue()
        let merged = existing.merging(value)

        var splices: [(range: Range<Int>, text: String)] = []
        var appended: [String] = []
        for part in wanted {
            guard let newValue = merged[part.key], existing[part.key] != newValue else { continue }
            let line = renderKey(part.key) + " = " + (try renderValue(newValue))
            for subtable in file.subtables(under: part.key) {
                splices.append((range: file.removalRange(of: subtable), text: ""))
            }
            let statements = file.tableStatements(for: part.key)
            guard let first = statements.first else {
                appended.append(line)
                continue
            }
            splices.append((range: file.lineRange(of: first), text: line + file.lineBreak(endingStatement: first)))
            splices += statements.dropFirst().map { (range: file.lineRange(of: $0), text: "") }
        }

        if let table = file.layout.table, !appended.isEmpty {
            let end = file.blockRange(of: table).upperBound
            let lead = end > 0 && file.bytes[end - 1] != 0x0A ? file.newline : ""
            splices.append((range: end..<end, text: lead + appended.map { $0 + file.newline }.joined()))
        }
        var result = file.applying(splices)
        if file.layout.table == nil, !appended.isEmpty {
            let header = "[" + target.map(renderKey).joined(separator: ".") + "]"
            result = appending(([header] + appended).map { $0 + file.newline }.joined(), to: result, newline: file.newline)
        }
        guard try member(name, at: keyPath, in: result) == merged else { throw MCPConfigEditError.verificationFailed }
        return result
    }

    private static func appending(_ block: String, to text: String, newline: String) -> String {
        var result = text
        if !result.isEmpty, result.utf8.last != 0x0A {
            result += newline
        }
        if !result.isEmpty, !endsWithBlankLine(result) {
            result += newline
        }
        return result + block
    }

    public static func removing(_ name: String, at keyPath: [String], in text: String) throws -> String {
        let file = try File(text: text, target: keyPath + [name])
        let blocks = (file.layout.table.map { [$0] } ?? []) + file.layout.subtables
        guard !blocks.isEmpty else { return text }
        let result = file.applying(blocks.map { (range: file.removalRange(of: $0), text: "") })
        guard try member(name, at: keyPath, in: result) == nil else { throw MCPConfigEditError.verificationFailed }
        return result
    }

    // Compared as bytes: Swift treats "\r\n" as one Character, so hasSuffix("\n") misses it.
    private static func endsWithBlankLine(_ text: String) -> Bool {
        var bytes = Array(text.utf8)
        guard bytes.last == 0x0A else { return false }
        bytes.removeLast()
        if bytes.last == 0x0D {
            bytes.removeLast()
        }
        return bytes.isEmpty || bytes.last == 0x0A
    }

    static func renderBlock(header: [String], value: JSONValue, newline: String) throws -> String {
        guard case .object(let members) = value else { throw MCPConfigEditError.unsupportedShape }
        var lines = ["[" + header.map(renderKey).joined(separator: ".") + "]"]
        for member in members {
            lines.append(renderKey(member.key) + " = " + (try renderValue(member.value)))
        }
        return lines.joined(separator: newline) + newline
    }

    static func renderKey(_ key: String) -> String {
        guard !key.isEmpty, key.utf8.allSatisfy(TOMLParser.isBareKeyByte) else { return quoted(key) }
        return key
    }

    static func renderValue(_ value: JSONValue) throws -> String {
        switch value {
        case .string(let string):
            return quoted(string)
        case .number(let number):
            if number.isNaN { return "nan" }
            if number.isInfinite { return number < 0 ? "-inf" : "inf" }
            return JSONTextStyle.numberText(number)
        case .bool(let bool):
            return bool ? "true" : "false"
        case .null:
            throw MCPConfigEditError.unsupportedShape
        case .array(let items):
            return "[" + (try items.map(renderValue)).joined(separator: ", ") + "]"
        case .object(let members):
            guard !members.isEmpty else { return "{}" }
            let pairs = try members.map { renderKey($0.key) + " = " + (try renderValue($0.value)) }
            return "{ " + pairs.joined(separator: ", ") + " }"
        }
    }

    static func quoted(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\u{08}": result += "\\b"
            case "\t": result += "\\t"
            case "\n": result += "\\n"
            case "\u{0C}": result += "\\f"
            case "\r": result += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    result += String(format: "\\u%04X", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }
}

private struct ServerLayout {
    var table: Int?
    var subtables: [Int] = []
    // A key on the way to the server holds a value (usually an inline table), so no [table] can be added under it.
    var containerIsValue = false
}

private struct File {
    let bytes: [UInt8]
    let statements: [TOMLStatement]
    let target: [String]
    let layout: ServerLayout
    let newline: String

    init(text: String, target: [String]) throws {
        bytes = Array(text.utf8)
        statements = try TOMLParser.parse(bytes)
        self.target = target
        newline = text.contains("\r\n") ? "\r\n" : "\n"
        layout = try Self.layout(statements, target: target)
    }

    private static func layout(_ statements: [TOMLStatement], target: [String]) throws -> ServerLayout {
        var layout = ServerLayout()
        var table: [String] = []
        for (position, statement) in statements.enumerated() {
            switch statement.kind {
            case let .table(keys, isArray):
                table = keys
                if isArray {
                    if keys.starts(with: target) || target.starts(with: keys) {
                        throw MCPConfigEditError.unsupportedShape
                    }
                } else if keys == target {
                    guard layout.table == nil else { throw MCPConfigEditError.duplicateKey(target) }
                    layout.table = position
                } else if keys.starts(with: target) {
                    layout.subtables.append(position)
                }
            case let .keyValue(keys, value):
                guard !table.starts(with: target) else { continue }
                let full = table + keys
                if full.starts(with: target) {
                    throw MCPConfigEditError.unsupportedShape
                }
                if target.starts(with: full) {
                    if Self.lookup(value, path: Array(target.dropFirst(full.count))) {
                        throw MCPConfigEditError.unsupportedShape
                    }
                    layout.containerIsValue = true
                }
            }
        }
        return layout
    }

    private static func lookup(_ value: JSONValue, path: [String]) -> Bool {
        var current = value
        for key in path {
            guard let next = current[key] else { return false }
            current = next
        }
        return true
    }

    func serverValue() throws -> JSONValue {
        var members: [(key: String, value: JSONValue)] = []
        let headers = ((layout.table.map { [$0] } ?? []) + layout.subtables).sorted()
        for header in headers {
            guard case let .table(keys, _) = statements[header].kind else { continue }
            let prefix = Array(keys.dropFirst(target.count))
            if !prefix.isEmpty {
                try ensureObject(at: prefix, in: &members)
            }
            for statement in statements[(header + 1)...] {
                guard case let .keyValue(keys, value) = statement.kind else { break }
                try TOMLTree.insert(value, at: prefix + keys, into: &members)
            }
        }
        return .object(members)
    }

    private func ensureObject(at path: [String], in members: inout [(key: String, value: JSONValue)]) throws {
        guard let key = path.first else { return }
        var children: [(key: String, value: JSONValue)] = []
        let position = members.firstIndex { $0.key == key }
        if let position {
            guard case .object(let existing) = members[position].value else { throw MCPConfigEditError.invalidSyntax }
            children = existing
        }
        try ensureObject(at: Array(path.dropFirst()), in: &children)
        if let position {
            members[position].value = .object(children)
        } else {
            members.append((key: key, value: .object(children)))
        }
    }

    func tableStatements(for key: String) -> [Int] {
        guard let table = layout.table else { return [] }
        var result: [Int] = []
        var position = table + 1
        while position < statements.count, case let .keyValue(keys, _) = statements[position].kind {
            if keys.first == key {
                result.append(position)
            }
            position += 1
        }
        return result
    }

    func subtables(under key: String) -> [Int] {
        layout.subtables.filter { header in
            guard case let .table(keys, _) = statements[header].kind else { return false }
            return keys.count > target.count && keys[target.count] == key
        }
    }

    func lineRange(of statement: Int) -> Range<Int> {
        statements[statement].lineStart..<statements[statement].lineEnd
    }

    func lineBreak(endingStatement statement: Int) -> String {
        let end = statements[statement].lineEnd
        guard end > 0, bytes[end - 1] == 0x0A else { return "" }
        return end > 1 && bytes[end - 2] == 0x0D ? "\r\n" : "\n"
    }

    func blockRange(of header: Int) -> Range<Int> {
        var last = header
        while last + 1 < statements.count, case .keyValue = statements[last + 1].kind {
            last += 1
        }
        return statements[header].lineStart..<statements[last].lineEnd
    }

    // Takes one blank line before the block too when a blank line or the end of the file follows it.
    func removalRange(of header: Int) -> Range<Int> {
        let range = blockRange(of: header)
        guard range.lowerBound > 0 else { return range }
        var previousStart = range.lowerBound - 1
        while previousStart > 0, bytes[previousStart - 1] != 0x0A {
            previousStart -= 1
        }
        guard isBlank(previousStart..<range.lowerBound) else { return range }
        var nextEnd = range.upperBound
        while nextEnd < bytes.count, bytes[nextEnd] != 0x0A {
            nextEnd += 1
        }
        guard range.upperBound == bytes.count || isBlank(range.upperBound..<nextEnd) else { return range }
        return previousStart..<range.upperBound
    }

    private func isBlank(_ range: Range<Int>) -> Bool {
        bytes[range].allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
    }

    // At one offset a removal goes before an insertion, or it would take the inserted text with it.
    func applying(_ splices: [(range: Range<Int>, text: String)]) -> String {
        var result = bytes
        let ordered = splices.sorted { left, right in
            left.range.lowerBound != right.range.lowerBound
                ? left.range.lowerBound > right.range.lowerBound
                : !left.range.isEmpty && right.range.isEmpty
        }
        for splice in ordered {
            result.replaceSubrange(splice.range, with: Array(splice.text.utf8))
        }
        return utf8Text(result)
    }
}
