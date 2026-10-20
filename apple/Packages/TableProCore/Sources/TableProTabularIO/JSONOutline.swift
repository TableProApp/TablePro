import Foundation

public struct JSONOutlineNode: Identifiable, Sendable {
    public enum Key: Sendable, Hashable {
        case root
        case member(String)
        case index(Int)
    }

    public enum Value: Sendable, Hashable {
        case object(count: Int)
        case array(count: Int)
        case string(String)
        case number(String)
        case bool(Bool)
        case null
    }

    // Nodes index one flat store, so a deep document neither builds nor frees a deep chain of arrays.
    private let storage: JSONOutlineStorage
    public let id: Int

    fileprivate init(storage: JSONOutlineStorage, id: Int) {
        self.storage = storage
        self.id = id
    }

    public var key: Key {
        storage.records[id].key
    }

    public var value: Value {
        storage.records[id].value
    }

    public var children: [JSONOutlineNode]? {
        let childIDs = storage.records[id].children
        guard !childIDs.isEmpty else { return nil }
        return childIDs.map { JSONOutlineNode(storage: storage, id: $0) }
    }

    public var keyPath: String {
        var keys: [Key] = []
        var current: Int? = id
        while let node = current {
            keys.append(storage.records[node].key)
            current = storage.records[node].parent
        }
        var path = "$"
        for key in keys.reversed() {
            switch key {
            case .root:
                continue
            case .member(let name):
                path += "." + JSONOutline.pathMember(name)
            case .index(let position):
                path += "[" + String(position) + "]"
            }
        }
        return path
    }

    public var copyText: String {
        let record = storage.records[id]
        return storage.source.withUnsafeBufferPointer { buffer -> String in
            let bytes = UnsafeBufferPointer(rebasing: buffer[record.range])
            switch record.value {
            case .object, .array:
                var compact: [UInt8] = []
                compact.reserveCapacity(bytes.count)
                JSONText.appendCompact(bytes, into: &compact)
                return compact.withUnsafeBufferPointer(JSONText.lossyString)
            case .string:
                return JSONText.decodedString(UnsafeBufferPointer(rebasing: bytes.dropFirst().dropLast()))
            case .number, .bool, .null:
                return JSONText.lossyString(bytes)
            }
        }
    }
}

public enum JSONOutline {
    public enum Result: Sendable {
        case tree(root: JSONOutlineNode, omitted: Int)
        case tooLarge
        case invalid
    }

    private static let maxLength = 100_000
    private static let maxNodes = 5_000
    private static let maxStringLength = 300

    public static func build(_ text: String) -> Result {
        guard text.utf16.count <= maxLength else { return .tooLarge }
        let source = Array(text.utf8)
        let walked = source.withUnsafeBufferPointer { bytes -> (records: [JSONOutlineRecord], omitted: Int)? in
            guard let base = bytes.baseAddress, (try? JSONRowParser.validateValue(in: bytes)) != nil else { return nil }
            return try? walk(JSONCursor(base: base, count: bytes.count, row: 0))
        }
        guard let walked else { return .invalid }
        let storage = JSONOutlineStorage(source: source, records: walked.records)
        return .tree(root: JSONOutlineNode(storage: storage, id: 0), omitted: walked.omitted)
    }

    // $."a.b" is the form SQLite, DuckDB, MariaDB and PostgreSQL all resolve to the key a.b.
    static func pathMember(_ key: String) -> String {
        guard !isIdentifier(key) else { return key }
        var quoted = "\""
        for scalar in key.unicodeScalars {
            if scalar == "\"" || scalar == "\\" { quoted.unicodeScalars.append("\\") }
            quoted.unicodeScalars.append(scalar)
        }
        quoted.unicodeScalars.append("\"")
        return quoted
    }

    private static func isIdentifier(_ key: String) -> Bool {
        var isFirst = true
        for byte in key.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "_"):
                break
            case UInt8(ascii: "0")...UInt8(ascii: "9") where !isFirst:
                break
            default:
                return false
            }
            isFirst = false
        }
        return !isFirst
    }

    private struct Frame {
        let record: Int?
        let isObject: Bool
        let start: Int
        var count = 0
    }

    // Runs on validated bytes, so it reads structure without re-checking it, and keeps counting past the node cap.
    private static func walk(_ cursor: JSONCursor) throws -> (records: [JSONOutlineRecord], omitted: Int) {
        var records: [JSONOutlineRecord] = []
        var stack: [Frame] = []
        var omitted = 0
        var key = JSONOutlineNode.Key.root
        var index = cursor.skipWhitespace(from: 0)
        while true {
            let parent = stack.last?.record
            let builds = records.count < maxNodes
            let byte = try peek(cursor, at: index)
            if byte == JSONByte.openBrace || byte == JSONByte.openBracket {
                let isObject = byte == JSONByte.openBrace
                var recordID: Int?
                if builds {
                    recordID = records.count
                    let empty: JSONOutlineNode.Value = isObject ? .object(count: 0) : .array(count: 0)
                    append(JSONOutlineRecord(key: key, value: empty, parent: parent, range: index..<index), to: &records)
                } else {
                    omitted += 1
                }
                stack.append(Frame(record: recordID, isObject: isObject, start: index))
                let next = cursor.skipWhitespace(from: index + 1)
                let close = isObject ? JSONByte.closeBrace : JSONByte.closeBracket
                if try peek(cursor, at: next) != close {
                    stack[stack.count - 1].count = 1
                    if isObject {
                        let first = try member(cursor, at: next)
                        key = first.key
                        index = first.valueStart
                    } else {
                        key = .index(0)
                        index = next
                    }
                    continue
                }
                index = next
            } else {
                let token = try cursor.value(at: index)
                if builds {
                    let leaf = leafValue(cursor, token: token, at: index)
                    append(JSONOutlineRecord(key: key, value: leaf, parent: parent, range: index..<token.end), to: &records)
                } else {
                    omitted += 1
                }
                index = cursor.skipWhitespace(from: token.end)
            }
            while let top = stack.last {
                if try peek(cursor, at: index) == JSONByte.comma {
                    stack[stack.count - 1].count += 1
                    let next = cursor.skipWhitespace(from: index + 1)
                    if top.isObject {
                        let following = try member(cursor, at: next)
                        key = following.key
                        index = following.valueStart
                    } else {
                        key = .index(top.count)
                        index = next
                    }
                    break
                }
                stack.removeLast()
                if let closed = top.record {
                    records[closed].value = top.isObject ? .object(count: top.count) : .array(count: top.count)
                    records[closed].range = top.start..<(index + 1)
                }
                index = cursor.skipWhitespace(from: index + 1)
            }
            if stack.isEmpty { return (records, omitted) }
        }
    }

    private static func append(_ record: JSONOutlineRecord, to records: inout [JSONOutlineRecord]) {
        if let parent = record.parent {
            records[parent].children.append(records.count)
        }
        records.append(record)
    }

    private static func peek(_ cursor: JSONCursor, at index: Int) throws -> UInt8 {
        guard index < cursor.count else { throw JSONTableError.truncated(row: cursor.row, byteOffset: cursor.count) }
        return cursor.base[index]
    }

    private static func member(_ cursor: JSONCursor, at start: Int) throws -> (key: JSONOutlineNode.Key, valueStart: Int) {
        let string = try cursor.string(at: start)
        let content = cursor.bytes((start + 1)..<(string.end - 1))
        let name = string.hasEscapes ? JSONText.decodedString(content) : JSONText.lossyString(content)
        let colon = cursor.skipWhitespace(from: string.end)
        return (.member(name), cursor.skipWhitespace(from: colon + 1))
    }

    private static func leafValue(_ cursor: JSONCursor, token: JSONValueToken, at start: Int) -> JSONOutlineNode.Value {
        switch token.kind {
        case .text:
            let content = cursor.bytes((start + 1)..<(token.end - 1))
            let text = token.needsRewrite ? JSONText.decodedString(content) : JSONText.lossyString(content)
            return .string(cut(text))
        case .number:
            return .number(JSONText.lossyString(cursor.bytes(start..<token.end)))
        case .boolean:
            return .bool(cursor.base[start] == JSONByte.letterT)
        default:
            return .null
        }
    }

    // Measured in UTF-16 units as the Mac tree does, cut only between whole characters.
    private static func cut(_ text: String) -> String {
        var index = text.startIndex
        var units = 0
        while index < text.endIndex {
            let next = text.index(after: index)
            units += text.utf16.distance(from: index, to: next)
            if units > maxStringLength { return String(text[..<index]) + "…" }
            index = next
        }
        return text
    }
}

private struct JSONOutlineRecord: Sendable {
    let key: JSONOutlineNode.Key
    var value: JSONOutlineNode.Value
    let parent: Int?
    var range: Range<Int>
    var children: [Int] = []
}

private final class JSONOutlineStorage: Sendable {
    let source: [UInt8]
    let records: [JSONOutlineRecord]

    init(source: [UInt8], records: [JSONOutlineRecord]) {
        self.source = source
        self.records = records
    }
}
