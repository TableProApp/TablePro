import Foundation

/// How one JSON text becomes one BSON document when libbson's reader would misread part of it.
///
/// libbson decides what an embedded object is from its first key alone. `$type`, `$regex` and
/// `$options` open its legacy binary and regular expression values, and they are also query
/// operators: `{"sig": {"$type": "binData"}}` fails with `Missing "$binary"`,
/// `{"$regex": "^a", "$exists": true}` fails with `Invalid key "$exists"`, and
/// `{"$regex": "a", "$options": "i"}` becomes a regular expression value. mongosh sends each of them
/// as the document it is written as. So does this: such an object is built member by member, and a
/// member is handed to libbson as a document of its own, `{"key": value}`, where a key is never
/// special. Every value that holds no such object is still read by libbson as written, wrappers
/// such as `{"$oid": …}` included.
enum MongoBsonAssembly: Equatable, Sendable {
    /// Text libbson reads as meant, which is nearly all of it.
    case whole(String)
    /// A document built from these parts, in order.
    case parts([Part])

    enum Part: Equatable, Sendable {
        /// A document of one member, which libbson reads as written.
        case member(String)
        case document(key: String, parts: [Part])
        /// Its parts are keyed `0`, `1` and on, the keys of a BSON array.
        case array(key: String, parts: [Part])
    }

    /// libbson's special keys that are also MongoDB operators.
    static let operatorKeys: Set<String> = ["$type", "$regex", "$options"]

    /// libbson's other special keys, each opening an Extended JSON value that is never taken apart.
    static let valueKeys: Set<String> = [
        "$binary", "$code", "$date", "$dbPointer", "$maxKey", "$minKey", "$numberDecimal", "$numberDouble",
        "$numberInt", "$numberLong", "$oid", "$regularExpression", "$scope", "$symbol", "$timestamp",
        "$undefined", "$uuid"
    ]

    static func plan(_ json: String) -> MongoBsonAssembly {
        guard holdsOperatorDocument(json), isWellFormed(json) else { return .whole(json) }
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") { return .parts(elementParts(of: trimmed)) }
        return .parts(memberParts(of: trimmed))
    }

    // MARK: - Planning

    private static func memberParts(of objectJson: String) -> [Part] {
        MongoScriptJson.members(of: objectJson).map { part(key: $0.key, value: $0.value) }
    }

    private static func elementParts(of arrayJson: String) -> [Part] {
        MongoScriptJson.topLevelElements(arrayJson).enumerated().map { part(key: String($0.offset), value: $0.element) }
    }

    private static func part(key: String, value: String) -> Part {
        guard isTakenApart(value) else { return .member("{\(MongoScriptJson.jsonString(key)):\(value)}") }
        if value.hasPrefix("[") { return .array(key: key, parts: elementParts(of: value)) }
        return .document(key: key, parts: memberParts(of: value))
    }

    /// An operator document is taken apart, and so is anything holding one. A value wrapper is
    /// not, whatever it holds: taking a `$code` with a `$scope` apart would store a document where
    /// the script wrote code.
    private static func isTakenApart(_ valueJson: String) -> Bool {
        guard valueJson.hasPrefix("{") || valueJson.hasPrefix("["),
              holdsOperatorDocument(valueJson, countingOutermost: true) else { return false }
        guard valueJson.hasPrefix("{") else { return true }
        let firstKey = MongoScriptJson.members(of: valueJson).first?.key
        return firstKey.map { !valueKeys.contains($0) } ?? false
    }

    private static func isWellFormed(_ json: String) -> Bool {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed)) != nil
    }

    // MARK: - Scanning

    /// Whether an object opens with an operator key once its escapes are decoded, as libbson
    /// decodes them. libbson never misreads the outermost object of what it parses, so that one
    /// counts only when `countingOutermost` is set.
    static func holdsOperatorDocument(_ json: String, countingOutermost: Bool = false) -> Bool {
        var text = json
        text.makeContiguousUTF8()
        let shallowest = countingOutermost ? 1 : 2
        return text.utf8.withContiguousStorageIfAvailable { scan($0, fromDepth: shallowest) } ?? false
    }

    private static let quote = UInt8(ascii: "\"")
    private static let backslash = UInt8(ascii: "\\")
    private static let dollar = UInt8(ascii: "$")

    private static func scan(_ bytes: UnsafeBufferPointer<UInt8>, fromDepth shallowest: Int) -> Bool {
        var depth = 0
        var awaitsFirstKey = false
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case quote:
                let end = stringEnd(in: bytes, from: index + 1)
                if awaitsFirstKey, depth >= shallowest, isOperatorKey(bytes[(index + 1) ..< end]) { return true }
                awaitsFirstKey = false
                index = end
            case UInt8(ascii: "{"):
                depth += 1
                awaitsFirstKey = true
            case UInt8(ascii: "["):
                depth += 1
                awaitsFirstKey = false
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
                awaitsFirstKey = false
            case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"):
                break
            default:
                awaitsFirstKey = false
            }
            index += 1
        }
        return false
    }

    /// The index of the quote that closes the string whose contents start at `start`.
    private static func stringEnd(in bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        var index = start
        while index < bytes.count {
            switch bytes[index] {
            case backslash: index += 2
            case quote: return index
            default: index += 1
            }
        }
        return bytes.count
    }

    private static let operatorKeyBytes = operatorKeys.map { Array($0.utf8) }

    private static func isOperatorKey(_ raw: Slice<UnsafeBufferPointer<UInt8>>) -> Bool {
        guard let first = raw.first, first == dollar || first == backslash else { return false }
        guard raw.contains(backslash) else { return operatorKeyBytes.contains { $0.elementsEqual(raw) } }
        let quoted = Data([quote] + raw + [quote])
        let decoded = try? JSONSerialization.jsonObject(with: quoted, options: .fragmentsAllowed) as? String
        return decoded.map(operatorKeys.contains) ?? false
    }
}
