import Foundation

/// What the host lets one statement do on the server.
enum MongoScriptAccess: Sendable, Equatable {
    case read
    case readWrite
}

/// The host calls a statement sent as a read may make.
///
/// The shell keeps its globals from one statement to the next, so a read's text proves nothing about
/// the code it runs: an earlier statement can have pointed `find` at `deleteMany`. A read is held to
/// what the unmodified prelude sends for a statement the app's grammar proves a read.
enum MongoScriptAccessPolicy {
    static let readOperations: Set<String> = [
        "currentDatabase", "useDatabase", "listCollections", "listIndexes", "countDocuments",
        "estimatedDocumentCount", "distinct", "collectionStats", "openCursor", "cursorConfigure",
        "cursorFetch", "cursorCount", "cursorExplain", "cursorClose", "newObjectId", "hexToBase64",
        "encodeUuid", "sleep"
    ]

    /// Lowercased. `explain`, `count`, `distinct` and `collStats` have ops of their own, and sent
    /// through `command` they can wrap a write.
    static let readCommands: Set<String> = [
        "listcollections", "dbstats", "buildinfo", "serverstatus", "hostinfo", "currentop", "listdatabases"
    ]

    static let writeStages: Set<String> = ["$out", "$merge"]

    static func allows(op: String, request: [String: Any], access: MongoScriptAccess) -> Bool {
        guard access == .read else { return true }
        guard op == "command" else { return readOperations.contains(op) }
        guard let document = MongoScriptJson.rawJson(request["command"]),
              let name = commandName(of: document) else {
            return false
        }
        return isReadCommand(name)
    }

    static func isReadCommand(_ name: String) -> Bool {
        name.unicodeScalars.allSatisfy(\.isASCII) && readCommands.contains(name.lowercased())
    }

    /// The op a refusal names: the command for `command`, since that is what the statement wrote.
    static func refusedName(op: String, request: [String: Any]) -> String {
        guard op == "command" else { return op }
        return MongoScriptJson.rawJson(request["command"]).flatMap(commandName(of:)) ?? op
    }

    /// The first member of a command document as libbson reads it, escapes decoded, or nil when the
    /// text does not open with one.
    static func commandName(of json: String) -> String? {
        StrictJsonKeys.firstKey(of: json)
    }

    /// Whether text sent to the server as a pipeline, aggregate options or a whole command carries a
    /// `$out` or `$merge` key at any depth. A string value spelled `"$out"` is a field path, not a
    /// stage. Text that is not strict JSON counts as writing.
    static func writesThroughPipeline(_ json: String) -> Bool {
        StrictJsonKeys.holdsKey(from: writeStages, in: json) ?? true
    }

    static func writes(pipeline: String, options: String?) -> Bool {
        writesThroughPipeline(pipeline) || options.map(writesThroughPipeline) == true
    }
}

/// Reads object keys the way libbson does. `JSONSerialization` keeps only the first of two equal keys
/// while libbson keeps and sends both, so a duplicate could hide a stage from it.
private struct StrictJsonKeys {
    private struct Malformed: Error {}

    /// libbson's own JSON reader stops at 100 levels, so nothing it would send is refused here.
    private static let maximumDepth = 200

    private let scalars: [Unicode.Scalar]
    private var index = 0

    private init(_ text: String) {
        scalars = Array(text.unicodeScalars)
    }

    static func firstKey(of text: String) -> String? {
        var reader = StrictJsonKeys(text)
        reader.skipWhitespace()
        guard reader.consume("{") else { return nil }
        reader.skipWhitespace()
        return try? reader.string()
    }

    /// Nil when the text is not one strict JSON object or array.
    static func holdsKey(from names: Set<String>, in text: String) -> Bool? {
        var reader = StrictJsonKeys(text)
        do {
            reader.skipWhitespace()
            guard reader.peek == "{" || reader.peek == "[" else { return nil }
            if try reader.value(depth: 0, names: names) { return true }
            reader.skipWhitespace()
            return reader.index == reader.scalars.count ? false : nil
        } catch {
            return nil
        }
    }

    private var peek: Unicode.Scalar? {
        index < scalars.count ? scalars[index] : nil
    }

    private mutating func consume(_ scalar: Unicode.Scalar) -> Bool {
        guard peek == scalar else { return false }
        index += 1
        return true
    }

    private mutating func expect(_ scalar: Unicode.Scalar) throws {
        guard consume(scalar) else { throw Malformed() }
    }

    private mutating func skipWhitespace() {
        while let scalar = peek, scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" {
            index += 1
        }
    }

    /// True as soon as a key in `names` is found; the rest is not read.
    private mutating func value(depth: Int, names: Set<String>) throws -> Bool {
        guard depth < Self.maximumDepth else { throw Malformed() }
        switch peek {
        case "{": return try object(depth: depth, names: names)
        case "[": return try array(depth: depth, names: names)
        case "\"": _ = try string()
        case "t": try literal("true")
        case "f": try literal("false")
        case "n": try literal("null")
        default: try number()
        }
        return false
    }

    private mutating func object(depth: Int, names: Set<String>) throws -> Bool {
        try expect("{")
        skipWhitespace()
        if consume("}") { return false }
        while true {
            skipWhitespace()
            let key = try string()
            if names.contains(key) { return true }
            skipWhitespace()
            try expect(":")
            skipWhitespace()
            if try value(depth: depth + 1, names: names) { return true }
            skipWhitespace()
            if consume("}") { return false }
            try expect(",")
        }
    }

    private mutating func array(depth: Int, names: Set<String>) throws -> Bool {
        try expect("[")
        skipWhitespace()
        if consume("]") { return false }
        while true {
            skipWhitespace()
            if try value(depth: depth + 1, names: names) { return true }
            skipWhitespace()
            if consume("]") { return false }
            try expect(",")
        }
    }

    private mutating func literal(_ word: String) throws {
        for scalar in word.unicodeScalars {
            try expect(scalar)
        }
    }

    private mutating func number() throws {
        _ = consume("-")
        if !consume("0") {
            guard digits() > 0 else { throw Malformed() }
        }
        if consume("."), digits() == 0 { throw Malformed() }
        if consume("e") || consume("E") {
            if !consume("+") { _ = consume("-") }
            guard digits() > 0 else { throw Malformed() }
        }
    }

    private mutating func digits() -> Int {
        var count = 0
        while let scalar = peek, ("0" ... "9").contains(scalar) {
            index += 1
            count += 1
        }
        return count
    }

    private mutating func string() throws -> String {
        try expect("\"")
        var decoded = String.UnicodeScalarView()
        while let scalar = peek {
            index += 1
            switch scalar {
            case "\"":
                return String(decoded)
            case "\\":
                let unescaped = try escape()
                decoded.append(unescaped)
            default:
                guard scalar.value >= 0x20 else { throw Malformed() }
                decoded.append(scalar)
            }
        }
        throw Malformed()
    }

    private mutating func escape() throws -> Unicode.Scalar {
        guard let marker = peek else { throw Malformed() }
        index += 1
        switch marker {
        case "\"", "\\", "/": return marker
        case "b": return "\u{08}"
        case "f": return "\u{0C}"
        case "n": return "\n"
        case "r": return "\r"
        case "t": return "\t"
        case "u": return try unicodeEscape()
        default: throw Malformed()
        }
    }

    private mutating func unicodeEscape() throws -> Unicode.Scalar {
        let unit = try hexUnit()
        if (0xDC00 ... 0xDFFF).contains(unit) { throw Malformed() }
        guard (0xD800 ... 0xDBFF).contains(unit) else {
            guard let scalar = Unicode.Scalar(unit) else { throw Malformed() }
            return scalar
        }
        try expect("\\")
        try expect("u")
        let low = try hexUnit()
        guard (0xDC00 ... 0xDFFF).contains(low),
              let scalar = Unicode.Scalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)) else {
            throw Malformed()
        }
        return scalar
    }

    private mutating func hexUnit() throws -> UInt32 {
        var unit: UInt32 = 0
        for _ in 0 ..< 4 {
            guard let scalar = peek, let digit = Self.hexValue(scalar) else { throw Malformed() }
            index += 1
            unit = unit << 4 | digit
        }
        return unit
    }

    private static func hexValue(_ scalar: Unicode.Scalar) -> UInt32? {
        switch scalar {
        case "0" ... "9": return scalar.value - 0x30
        case "a" ... "f": return scalar.value - 0x61 + 10
        case "A" ... "F": return scalar.value - 0x41 + 10
        default: return nil
        }
    }
}
