import Foundation
import TableProSQLGrammar

// The app's own statements run as `.read` or `.readWrite`. An external caller's approval can also take away
// dropping or deleting data and running code on the server, for a read as well as a write.
nonisolated struct MongoScriptAccess: Sendable, Equatable {
    var writes: Bool
    var allowsDestructive: Bool
    var allowsServerCode: Bool

    static let read = MongoScriptAccess(writes: false, allowsDestructive: false, allowsServerCode: true)
    static let readWrite = MongoScriptAccess(writes: true, allowsDestructive: true, allowsServerCode: true)
}

nonisolated enum MongoScriptRefusal: Sendable, Equatable {
    case read(String)
    case destructive(String)
    case serverCode(String)

    var message: String {
        switch self {
        case .read(let name): return MongoScriptText.refusedUnderRead(name)
        case .destructive(let name): return MongoScriptText.refusedDestructive(name)
        case .serverCode(let name): return MongoScriptText.refusedServerCode(name)
        }
    }
}

// Checked at the host op, not on the statement's text: the shell keeps its globals from one statement to the next, so
// an earlier statement can have pointed `find` at `deleteMany`, and any script can call `__tp_exec` with any op.
nonisolated enum MongoScriptAccessPolicy {
    static let readOperations: Set<String> = [
        "currentDatabase", "useDatabase", "listCollections", "listIndexes", "countDocuments",
        "estimatedDocumentCount", "distinct", "collectionStats", "openCursor", "cursorConfigure",
        "cursorFetch", "cursorCount", "cursorExplain", "cursorClose", "newObjectId", "hexToBase64",
        "encodeUuid", "sleep"
    ]

    // Lowercased. `explain`, `count`, `distinct` and `collStats` have ops of their own, and sent through `command` they
    // can wrap a write.
    static let readCommands: Set<String> = [
        "listcollections", "dbstats", "buildinfo", "serverstatus", "hostinfo", "currentop", "listdatabases"
    ]

    static let writeStages: Set<String> = ["$out", "$merge"]

    // Server-side JavaScript, plus the two stages that write to a collection the pipeline names.
    static let serverCodeKeys: Set<String> = ["$where", "$function", "$accumulator", "$out", "$merge"]

    // The server takes its own operators from any client, and rewrites `mapReduce` into two that run a function.
    static let internalOperatorPrefix = "$_internal"

    // Lowercased. `$eval` and `group` ran JavaScript on servers before 4.2.
    static let serverCodeCommands = MongoCommandCatalog.serverCodeCommands

    private static let documentMembers: [String: [String]] = [
        "openCursor": ["filter", "projection", "pipeline", "options"],
        "cursorConfigure": ["value"],
        "command": ["command"],
        "countDocuments": ["filter"],
        "distinct": ["filter"],
        "insertOne": ["document", "options"],
        "insertMany": ["documents", "options"],
        "update": ["filter", "update", "options"],
        "replace": ["filter", "update", "options"],
        "delete": ["filter", "options"],
        "findAndModify": ["filter", "update", "options"],
        "bulkWrite": ["operations", "options"],
        "createIndex": ["keys", "options"],
        "dropIndex": ["index"]
    ]

    static func refusal(op: String, request: [String: Any], access: MongoScriptAccess) -> MongoScriptRefusal? {
        let name = refusedName(op: op, request: request)
        if !access.writes, !readAllows(op: op, request: request) { return .read(name) }
        if !access.allowsDestructive, destroys(op: op, request: request) { return .destructive(name) }
        if !access.allowsServerCode, runsServerCode(op: op, request: request) { return .serverCode(name) }
        return nil
    }

    static func isReadCommand(_ name: String) -> Bool {
        name.unicodeScalars.allSatisfy(\.isASCII) && readCommands.contains(name.lowercased())
    }

    // The name the statement wrote rather than the host op: the command, the cursor's method, the modifier.
    static func refusedName(op: String, request: [String: Any]) -> String {
        switch op {
        case "command": return commandName(in: request) ?? op
        case "openCursor": return (request["kind"] as? String) == "aggregate" ? "aggregate" : "find"
        case "cursorConfigure": return (request["key"] as? String) ?? op
        default: return op
        }
    }

    // The first member of a command document as libbson reads it, escapes decoded, or nil when the text does not open
    // with one.
    static func commandName(of json: String) -> String? {
        StrictJsonKeys.firstKey(of: json)
    }

    // `multi` as the host reads it when it builds the delete.
    static func deletesMany(_ request: [String: Any]) -> Bool {
        request["multi"] as? Bool ?? false
    }

    // A string value spelled `"$out"` is a field path, not a stage. Text that is not strict JSON counts as writing.
    static func writesThroughPipeline(_ json: String) -> Bool {
        StrictJsonKeys.holdsKey(from: writeStages, in: json) ?? true
    }

    static func writes(pipeline: String, options: String?) -> Bool {
        writesThroughPipeline(pipeline) || options.map(writesThroughPipeline) == true
    }

    // At any depth. Text that is not strict JSON counts as holding some.
    static func holdsServerCode(_ json: String) -> Bool {
        StrictJsonKeys.holdsKey(in: json) { serverCodeKeys.contains($0) || $0.hasPrefix(internalOperatorPrefix) } ?? true
    }

    private static func commandName(in request: [String: Any]) -> String? {
        MongoScriptJson.rawJson(request["command"]).flatMap(commandName(of:))
    }

    private static func readAllows(op: String, request: [String: Any]) -> Bool {
        guard op == "command" else { return readOperations.contains(op) }
        return commandName(in: request).map(isReadCommand) == true
    }

    private static func destroys(op: String, request: [String: Any]) -> Bool {
        switch op {
        case "dropCollection", "dropIndex", "renameCollection":
            return true
        case "delete":
            return deletesMany(request)
        case "bulkWrite":
            // An operation the host cannot build fails the whole bulkWrite before it sends anything.
            let statements = try? MongoScriptCommandBuilder.bulkStatements(
                operations: MongoScriptJson.rawJson(request["operations"]),
                collection: (request["collection"] as? String) ?? "",
                writeConcern: nil
            )
            return statements?.contains { $0.kind == .delete && $0.touchesMany } ?? true
        case "command":
            guard let name = commandName(in: request), MongoCommandCatalog.preserves(name) else { return true }
            let expiring = ["createindexes", "collmod"].contains(name.lowercased())
            return expiring && holdsExpiringOption(MongoScriptJson.rawJson(request["command"]))
        case "createIndex":
            return holdsExpiringOption(MongoScriptJson.rawJson(request["options"]))
                || holdsExpiringOption(MongoScriptJson.rawJson(request["keys"]))
        default:
            return false
        }
    }

    // At any depth; text that is not strict JSON counts as holding one.
    private static func holdsExpiringOption(_ json: String?) -> Bool {
        guard let json else { return false }
        return StrictJsonKeys.holdsKey(in: json) { MongoCommandCatalog.expiringOptions.contains($0) } ?? true
    }

    private static func runsServerCode(op: String, request: [String: Any]) -> Bool {
        if op == "command", let command = MongoScriptJson.rawJson(request["command"]) {
            if let name = commandName(of: command), serverCodeCommands.contains(name.lowercased()) { return true }
            // `explain` runs the command it wraps, and `executionStats` runs a mapReduce's functions.
            let wrapsCode = StrictJsonKeys.holdsKey(in: command) { ["mapreduce", "$eval"].contains($0.lowercased()) }
            if wrapsCode ?? true { return true }
        }
        return (documentMembers[op] ?? []).contains { member in
            MongoScriptJson.rawJson(request[member]).map(holdsServerCode) == true
        }
    }
}

/// Reads object keys the way libbson does. `JSONSerialization` keeps only the first of two equal keys
/// while libbson keeps and sends both, so a duplicate could hide a stage from it.
nonisolated private struct StrictJsonKeys {
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
        holdsKey(in: text, scalarAllowed: false) { names.contains($0) }
    }

    // Nil when the text is not one strict JSON value.
    static func holdsKey(in text: String, where matches: (String) -> Bool) -> Bool? {
        holdsKey(in: text, scalarAllowed: true, where: matches)
    }

    private static func holdsKey(in text: String, scalarAllowed: Bool, where matches: (String) -> Bool) -> Bool? {
        var reader = StrictJsonKeys(text)
        do {
            reader.skipWhitespace()
            guard scalarAllowed || reader.peek == "{" || reader.peek == "[" else { return nil }
            if try reader.value(depth: 0, matches: matches) { return true }
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

    // True as soon as a matching key is found; the rest is not read.
    private mutating func value(depth: Int, matches: (String) -> Bool) throws -> Bool {
        guard depth < Self.maximumDepth else { throw Malformed() }
        switch peek {
        case "{": return try object(depth: depth, matches: matches)
        case "[": return try array(depth: depth, matches: matches)
        case "\"": _ = try string()
        case "t": try literal("true")
        case "f": try literal("false")
        case "n": try literal("null")
        default: try number()
        }
        return false
    }

    private mutating func object(depth: Int, matches: (String) -> Bool) throws -> Bool {
        try expect("{")
        skipWhitespace()
        if consume("}") { return false }
        while true {
            skipWhitespace()
            let key = try string()
            if matches(key) { return true }
            skipWhitespace()
            try expect(":")
            skipWhitespace()
            if try value(depth: depth + 1, matches: matches) { return true }
            skipWhitespace()
            if consume("}") { return false }
            try expect(",")
        }
    }

    private mutating func array(depth: Int, matches: (String) -> Bool) throws -> Bool {
        try expect("[")
        skipWhitespace()
        if consume("]") { return false }
        while true {
            skipWhitespace()
            if try value(depth: depth + 1, matches: matches) { return true }
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
