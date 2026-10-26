import Foundation

public struct OracleJDWPMethod: Sendable, Hashable {
    public let id: UInt64
    public let name: String
    public let signature: String

    public init(id: UInt64, name: String, signature: String) {
        self.id = id
        self.name = name
        self.signature = signature
    }

    // A unit compiled without debug information lists `<procedure$N>` methods with empty line tables (measured).
    public var isSubprogram: Bool {
        !name.hasPrefix("<")
    }

    public var argumentTypeNames: [String] {
        guard let open = signature.firstIndex(of: "("), let close = signature.firstIndex(of: ")") else { return [] }
        var names: [String] = []
        var current = ""
        for character in signature[signature.index(after: open)..<close] {
            current.append(character)
            if character == ";" {
                names.append(OracleDebugUnit.typeName(fromJDWPSignature: current))
                current = ""
            }
        }
        return names
    }

    static func decodeList(_ data: Data, sizes: OracleJDWPIDSizes) throws -> [OracleJDWPMethod] {
        var reader = OracleJDWPReader(data, sizes: sizes)
        let count = try reader.count(minimumSize: sizes.method + 12)
        var methods: [OracleJDWPMethod] = []
        for _ in 0..<count {
            let id = try reader.id(.method)
            let name = try reader.string()
            let signature = try reader.string()
            _ = try reader.i32()
            methods.append(OracleJDWPMethod(id: id, name: name, signature: signature))
        }
        return methods
    }
}

// Oracle's code index is the source line (measured), but lines are still read through the table.
public struct OracleJDWPLineTable: Sendable, Equatable {
    public let start: Int64
    public let end: Int64
    public let entries: [(index: Int64, line: Int)]

    public init(start: Int64, end: Int64, entries: [(index: Int64, line: Int)]) {
        self.start = start
        self.end = end
        self.entries = entries.sorted { $0.index < $1.index }
    }

    public static func == (lhs: OracleJDWPLineTable, rhs: OracleJDWPLineTable) -> Bool {
        lhs.start == rhs.start && lhs.end == rhs.end
            && lhs.entries.map(\.index) == rhs.entries.map(\.index)
            && lhs.entries.map(\.line) == rhs.entries.map(\.line)
    }

    static func decode(_ data: Data, sizes: OracleJDWPIDSizes) throws -> OracleJDWPLineTable {
        var reader = OracleJDWPReader(data, sizes: sizes)
        let start = try reader.i64()
        let end = try reader.i64()
        let count = try reader.count(minimumSize: 12)
        var entries: [(index: Int64, line: Int)] = []
        for _ in 0..<count {
            let index = try reader.i64()
            let line = Int(try reader.i32())
            entries.append((index, line))
        }
        return OracleJDWPLineTable(start: start, end: end, entries: entries)
    }

    public var isEmpty: Bool { entries.isEmpty }

    public var lines: [Int] { entries.map(\.line) }

    public var firstLine: Int? { entries.first?.line }

    public func covers(line: Int) -> Bool {
        guard let first = entries.map(\.line).min(), let last = entries.map(\.line).max() else { return false }
        return line >= first && line <= last
    }

    // The code index for `line`, or for the next line after it that has code, within this method.
    public func location(atOrAfter line: Int) -> (index: Int64, line: Int)? {
        entries.filter { $0.line >= line }.min { $0.line == $1.line ? $0.index < $1.index : $0.line < $1.line }
    }

    public func line(at index: Int64) -> Int? {
        if let exact = entries.first(where: { $0.index == index }) { return exact.line }
        return entries.last(where: { $0.index <= index })?.line
    }
}

public struct OracleJDWPVariable: Sendable, Hashable {
    public let codeIndex: Int64
    public let name: String
    public let signature: String
    public let length: Int
    public let slot: Int
    public let isArgument: Bool

    public init(codeIndex: Int64, name: String, signature: String, length: Int, slot: Int, isArgument: Bool) {
        self.codeIndex = codeIndex
        self.name = name
        self.signature = signature
        self.length = length
        self.slot = slot
        self.isArgument = isArgument
    }

    // `_return` and the like are the engine's own slots.
    public var isUserVariable: Bool {
        !name.hasPrefix("_")
    }

    // A loop index is in scope only inside its loop: `I` measured at code index 13, length 3.
    public func isVisible(at index: Int64) -> Bool {
        let (end, overflow) = codeIndex.addingReportingOverflow(Int64(max(length, 1)))
        return index >= codeIndex && (overflow || index < end)
    }

    static func decodeTable(_ data: Data, sizes: OracleJDWPIDSizes) throws -> [OracleJDWPVariable] {
        var reader = OracleJDWPReader(data, sizes: sizes)
        let argumentCount = Int(try reader.i32())
        let count = try reader.count(minimumSize: 24)
        var variables: [OracleJDWPVariable] = []
        for _ in 0..<count {
            let codeIndex = try reader.i64()
            let name = try reader.string()
            let signature = try reader.string()
            let length = Int(try reader.i32())
            let slot = Int(try reader.i32())
            guard length >= 0, slot >= 0, !codeIndex.addingReportingOverflow(Int64(length)).overflow else {
                throw OracleJDWPError.malformedPacket
            }
            variables.append(OracleJDWPVariable(
                codeIndex: codeIndex,
                name: name,
                signature: signature,
                length: length,
                slot: slot,
                isArgument: slot < argumentCount
            ))
        }
        return variables
    }
}

public struct OracleJDWPField: Sendable, Hashable {
    public let id: UInt64
    public let name: String
    public let signature: String
    public let modifiers: Int32

    public init(id: UInt64, name: String, signature: String, modifiers: Int32) {
        self.id = id
        self.name = name
        self.signature = signature
        self.modifiers = modifiers
    }

    public var isStatic: Bool { modifiers & 0x0008 != 0 }

    static func decodeList(_ data: Data, sizes: OracleJDWPIDSizes) throws -> [OracleJDWPField] {
        var reader = OracleJDWPReader(data, sizes: sizes)
        let count = try reader.count(minimumSize: sizes.field + 12)
        var fields: [OracleJDWPField] = []
        for _ in 0..<count {
            fields.append(OracleJDWPField(
                id: try reader.id(.field),
                name: try reader.string(),
                signature: try reader.string(),
                modifiers: try reader.i32()
            ))
        }
        return fields
    }
}

// How a PL/SQL value is wrapped: a scalar is an object whose `_value` string holds the text (a null string for SQL
// NULL), a record has one field per member and `_type` 'record', a collection keeps its elements in `_values`.
public enum OracleDebugValueShape: Sendable, Equatable {
    case scalar(valueField: UInt64)
    case record(members: [OracleJDWPField])
    case collection(valuesField: UInt64)
    case opaque

    public static let valueFieldName = "_value"
    public static let valuesFieldName = "_values"

    public init(fields: [OracleJDWPField]) {
        let instance = fields.filter { !$0.isStatic }
        if let value = instance.first(where: { $0.name == Self.valueFieldName }) {
            self = .scalar(valueField: value.id)
        } else if let values = instance.first(where: { $0.name == Self.valuesFieldName }) {
            self = .collection(valuesField: values.id)
        } else {
            let members = instance.filter { !$0.name.hasPrefix("_") }
            self = members.isEmpty ? .opaque : .record(members: members)
        }
    }
}

public struct OracleDebugRecordMember: Sendable, Hashable {
    public let name: String
    public let value: String?

    public init(name: String, value: String?) {
        self.name = name
        self.value = value
    }
}

public enum OracleDebugValue: Sendable, Hashable {
    case scalar(String?)
    case record([OracleDebugRecordMember])
    case collection(count: Int?)
    case unavailable
}
