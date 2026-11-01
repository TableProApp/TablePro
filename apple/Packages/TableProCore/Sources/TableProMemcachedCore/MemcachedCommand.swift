import Foundation

public enum MemcachedStorageVerb: String, CaseIterable, Sendable {
    case set, add, replace, append, prepend
}

/// One statement of the console, in the order the text protocol takes its arguments. A value is the last argument
/// of the line instead of a data block, so a statement stays one line the review sheet can show.
public enum MemcachedCommand: Equatable, Sendable {
    case get(keys: [String], withCAS: Bool)
    case getAndTouch(exptime: Int64, keys: [String], withCAS: Bool)
    case store(MemcachedStorageVerb, key: String, flags: UInt32, exptime: Int64, value: Data)
    case compareAndSwap(key: String, flags: UInt32, exptime: Int64, unique: UInt64, value: Data)
    case touch(key: String, exptime: Int64)
    case delete(key: String)
    case increment(key: String, delta: UInt64)
    case decrement(key: String, delta: UInt64)
    case flushAll(delay: Int64?)
    case stats(arguments: [String])
    case version
    case metadump(selector: String)

    public var replyShape: MemcachedReplyShape {
        switch self {
        case .get, .getAndTouch: return .values
        case .stats, .metadump: return .lines
        default: return .status
        }
    }

    /// The bytes the text protocol takes for this command, data block included.
    public var wireBytes: [UInt8] {
        func line(_ words: [String]) -> [UInt8] { Array((words.joined(separator: " ") + "\r\n").utf8) }
        func block(_ head: [String], _ value: Data) -> [UInt8] {
            line(head + [String(value.count)]) + Array(value) + Array("\r\n".utf8)
        }
        switch self {
        case .get(let keys, let withCAS):
            return line([withCAS ? "gets" : "get"] + keys)
        case .getAndTouch(let exptime, let keys, let withCAS):
            return line([withCAS ? "gats" : "gat", String(exptime)] + keys)
        case .store(let verb, let key, let flags, let exptime, let value):
            return block([verb.rawValue, key, String(flags), String(exptime)], value)
        case .compareAndSwap(let key, let flags, let exptime, let unique, let value):
            return line(["cas", key, String(flags), String(exptime), String(value.count), String(unique)])
                + Array(value) + Array("\r\n".utf8)
        case .touch(let key, let exptime):
            return line(["touch", key, String(exptime)])
        case .delete(let key):
            return line(["delete", key])
        case .increment(let key, let delta):
            return line(["incr", key, String(delta)])
        case .decrement(let key, let delta):
            return line(["decr", key, String(delta)])
        case .flushAll(let delay):
            return line(["flush_all"] + (delay.map { [String($0)] } ?? []))
        case .stats(let arguments):
            return line(["stats"] + arguments)
        case .version:
            return line(["version"])
        case .metadump(let selector):
            return line(["lru_crawler", "metadump", selector])
        }
    }
}

public enum MemcachedCommandError: Error, Equatable, Sendable {
    case empty
    case unknownCommand(String)
    case wrongArguments(command: String, usage: String)
    case invalidKey(String)
    case invalidNumber(String)
    case unterminatedQuote
}

public enum MemcachedCommandParser {
    /// The longest key memcached accepts, in bytes.
    public static let maximumKeyLength = 250

    public static func parse(_ statement: String) throws(MemcachedCommandError) -> MemcachedCommand {
        let words = try tokenize(statement)
        guard let first = words.first else { throw .empty }
        let name = Self.text(first).lowercased()
        let arguments = Array(words.dropFirst())
        func text(_ index: Int) -> String { Self.text(arguments[index]) }
        func usage(_ form: String) -> MemcachedCommandError { .wrongArguments(command: name, usage: form) }

        switch name {
        case "get", "gets":
            guard !arguments.isEmpty else { throw usage("\(name) <key> [<key>...]") }
            return .get(keys: try keys(arguments[...]), withCAS: name == "gets")
        case "gat", "gats":
            guard arguments.count >= 2 else { throw usage("\(name) <exptime> <key> [<key>...]") }
            return .getAndTouch(
                exptime: try integer(text(0)), keys: try keys(arguments.dropFirst()), withCAS: name == "gats"
            )
        case "set", "add", "replace", "append", "prepend":
            guard arguments.count == 4, let verb = MemcachedStorageVerb(rawValue: name) else {
                throw usage("\(name) <key> <flags> <exptime> <value>")
            }
            return .store(
                verb, key: try key(arguments[0]), flags: try flags(text(1)), exptime: try integer(text(2)),
                value: Data(arguments[3])
            )
        case "cas":
            guard arguments.count == 5 else { throw usage("cas <key> <flags> <exptime> <cas unique> <value>") }
            return .compareAndSwap(
                key: try key(arguments[0]), flags: try flags(text(1)), exptime: try integer(text(2)),
                unique: try unsigned(text(3)), value: Data(arguments[4])
            )
        case "touch":
            guard arguments.count == 2 else { throw usage("touch <key> <exptime>") }
            return .touch(key: try key(arguments[0]), exptime: try integer(text(1)))
        case "delete":
            guard arguments.count == 1 else { throw usage("delete <key>") }
            return .delete(key: try key(arguments[0]))
        case "incr", "decr":
            guard arguments.count == 2 else { throw usage("\(name) <key> <delta>") }
            let key = try key(arguments[0])
            let delta = try unsigned(text(1))
            return name == "incr" ? .increment(key: key, delta: delta) : .decrement(key: key, delta: delta)
        case "flush_all":
            guard arguments.count <= 1 else { throw usage("flush_all [<delay>]") }
            return .flushAll(delay: try arguments.isEmpty ? nil : integer(text(0)))
        case "stats":
            let words = arguments.indices.map(text)
            guard words.allSatisfy(isPlainWord) else { throw usage("stats [<group> [<arguments>]]") }
            return .stats(arguments: words)
        case "version":
            guard arguments.isEmpty else { throw usage("version") }
            return .version
        case "lru_crawler":
            guard arguments.count == 2, text(0).lowercased() == "metadump", isPlainWord(text(1)) else {
                throw usage("lru_crawler metadump <all|hash|slab ids>")
            }
            return .metadump(selector: text(1))
        default:
            throw .unknownCommand(name)
        }
    }

    /// Writes a value so `parse` reads it back byte for byte.
    public static func quoted(_ value: String) -> String {
        escaped(Array(value.utf8), keepingUTF8: true)
    }

    /// Writes bytes that may not be UTF-8, every byte past ASCII as `\xHH`.
    public static func quoted(bytes: Data) -> String {
        escaped(Array(bytes), keepingUTF8: false)
    }

    private static func escaped(_ bytes: [UInt8], keepingUTF8: Bool) -> String {
        var out: [UInt8] = [0x22]
        for byte in bytes {
            switch byte {
            case 0x22: out += Array(#"\""#.utf8)
            case 0x5C: out += Array(#"\\"#.utf8)
            case 0x0A: out += Array(#"\n"#.utf8)
            case 0x0D: out += Array(#"\r"#.utf8)
            case 0x09: out += Array(#"\t"#.utf8)
            case 0x20 ..< 0x7F: out.append(byte)
            case 0x80...: out += keepingUTF8 ? [byte] : Array(String(format: #"\x%02X"#, byte).utf8)
            default: out += Array(String(format: #"\x%02X"#, byte).utf8)
            }
        }
        out.append(0x22)
        return text(out)
    }

    /// Splits a line on whitespace. Double quotes take `\n`, `\r`, `\t`, `\xHH`, `\"` and `\\`; single quotes
    /// take everything as written.
    static func tokenize(_ text: String) throws(MemcachedCommandError) -> [[UInt8]] {
        var words: [[UInt8]] = []
        var current: [UInt8] = []
        var inWord = false
        var scalars = Array(text.unicodeScalars)[...]
        while let scalar = scalars.popFirst() {
            switch scalar {
            case " ", "\t", "\n", "\r":
                if inWord { words.append(current); current = []; inWord = false }
            case "'":
                inWord = true
                guard let end = scalars.firstIndex(of: "'") else { throw .unterminatedQuote }
                current += Array(String(String.UnicodeScalarView(scalars[..<end])).utf8)
                scalars = scalars[(end + 1)...]
            case "\"":
                inWord = true
                try readDoubleQuoted(&scalars, into: &current)
            default:
                inWord = true
                current += Array(String(scalar).utf8)
            }
        }
        if inWord { words.append(current) }
        return words
    }

    private static func readDoubleQuoted(
        _ scalars: inout ArraySlice<Unicode.Scalar>,
        into current: inout [UInt8]
    ) throws(MemcachedCommandError) {
        while let scalar = scalars.popFirst() {
            switch scalar {
            case "\"":
                return
            case "\\":
                guard let escaped = scalars.popFirst() else { throw .unterminatedQuote }
                switch escaped {
                case "n": current.append(0x0A)
                case "r": current.append(0x0D)
                case "t": current.append(0x09)
                case "x":
                    let digits = String(String.UnicodeScalarView(scalars.prefix(2)))
                    guard digits.count == 2, let byte = UInt8(digits, radix: 16) else {
                        current += Array("\\x".utf8)
                        continue
                    }
                    current.append(byte)
                    scalars = scalars.dropFirst(2)
                default: current += Array(String(escaped).utf8)
                }
            default:
                current += Array(String(scalar).utf8)
            }
        }
        throw .unterminatedQuote
    }

    /// A key is 1 to 250 bytes with no space or control character, the limits memcached's text protocol sets.
    public static func isValidKey(_ bytes: [UInt8]) -> Bool {
        !bytes.isEmpty && bytes.count <= maximumKeyLength && !bytes.contains { $0 <= 0x20 || $0 == 0x7F }
    }

    private static func key(_ bytes: [UInt8]) throws(MemcachedCommandError) -> String {
        let text = Self.text(bytes)
        guard isValidKey(bytes) else { throw .invalidKey(text) }
        return text
    }

    private static func keys(_ words: ArraySlice<[UInt8]>) throws(MemcachedCommandError) -> [String] {
        var keys: [String] = []
        for word in words { keys.append(try key(word)) }
        return keys
    }

    /// Bytes as text for a message or a number, never for a value: a byte that is not UTF-8 reads as Latin-1.
    static func text(_ bytes: [UInt8]) -> String {
        String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? ""
    }

    private static func isPlainWord(_ word: String) -> Bool {
        isValidKey(Array(word.utf8))
    }

    private static func integer(_ text: String) throws(MemcachedCommandError) -> Int64 {
        guard let value = Int64(text) else { throw .invalidNumber(text) }
        return value
    }

    private static func unsigned(_ text: String) throws(MemcachedCommandError) -> UInt64 {
        guard let value = UInt64(text) else { throw .invalidNumber(text) }
        return value
    }

    private static func flags(_ text: String) throws(MemcachedCommandError) -> UInt32 {
        guard let value = UInt32(text) else { throw .invalidNumber(text) }
        return value
    }
}
