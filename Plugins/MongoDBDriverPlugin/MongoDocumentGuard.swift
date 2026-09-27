import Foundation

/// The filter that lets a replacement through only while the stored document is exactly the one the
/// user opened.
///
/// A plain match is not equality: `null` matches a missing field, `5` matches `[5, 6]`, and `5`
/// matches `NumberLong(5)`. So the filter compares the whole document with `$$ROOT`, which under the
/// simple collation covers every field name, their order and every value, and then compares a type
/// signature, which covers what `$eq` treats as equal: the numeric type, a decimal's trailing zeros,
/// the sign of a zero, and a string against a symbol.
///
/// The signature is one `$map` per nesting level rather than one expression per field, so its size
/// grows with the depth of the document and not with its length. Every operator in it answers for
/// any input, because the server may evaluate the second `$and` operand even when the first is
/// false, and an operator that raises on what the document holds now would fail the save instead of
/// refusing it.
///
/// Two values are compared by what they mean and nothing in an expression can see their bytes, so a
/// document holding one is refused rather than guarded: every NaN equals every other whatever its
/// sign and payload, and a JavaScript scope is compared the way a query compares, so `1` equals
/// `NumberLong(1)` inside it (both measured on MongoDB 7.0).
enum MongoDocumentGuard {
    /// The deepest document whose filter libbson still reads. Its JSON reader stops at 98 levels
    /// and the signature spends three of them on each level of the document, so a 28-level
    /// document's filter reads and a 29-level one's does not (measured on libbson 1.28.1).
    static let maximumDepth = 28

    enum Refusal: Error, Equatable, LocalizedError {
        case tooDeep
        case unreadableValue
        case notANumber
        case codeWithScope

        var errorDescription: String? {
            switch self {
            case .tooDeep:
                return String(
                    format: String(localized: "This document is nested more than %d levels deep, which is too deep to edit here."),
                    MongoDocumentGuard.maximumDepth
                )
            case .unreadableValue:
                return String(localized: "This document holds a value that cannot be edited as text.")
            case .notANumber:
                return String(
                    localized: "This document holds a NaN. MongoDB treats every NaN as the same value, so a save could not tell whether someone else changed it."
                )
            case .codeWithScope:
                return String(
                    localized: "This document holds JavaScript code with a scope. MongoDB compares a scope by value, so a save could not tell whether someone else changed it."
                )
            }
        }
    }

    static func filter(for original: MongoDocumentText) throws -> String {
        let root = MongoDocumentText.Value.object(original.members)
        let depth = try self.depth(of: root)
        guard depth <= maximumDepth else { throw Refusal.tooDeep }
        guard let identity = original.value(of: MongoDocumentIdentity.field) else {
            throw MongoDBDocumentEditingError.missingIdentity
        }
        let expected = try expectedSignature(ofContainer: root, depth: depth).compactText
        let wholeDocument = #"{"$eq":["$$ROOT",{"$literal":\#(root.compactText)}]}"#
        let types = #"{"$eq":[\#(signature(of: rootVariable, depth: depth)),{"$literal":\#(expected)}]}"#
        return #"{"_id":\#(identity.compactText),"$expr":{"$and":[\#(wholeDocument),\#(types)]}}"#
    }

    /// How many containers deep a value goes. A type marker such as `{"$oid": "…"}` is one value,
    /// not a subdocument.
    static func depth(of value: MongoDocumentText.Value) throws -> Int {
        guard let type = MongoExtendedJsonType.name(of: value) else { throw Refusal.unreadableValue }
        guard type == "object" || type == "array" else { return 0 }
        let deepest = try children(of: value).map { try depth(of: $0) }.max() ?? 0
        return deepest + 1
    }

    // MARK: - Server side

    private static let rootVariable = #""$$ROOT""#
    private static let elementVariable = #""$$this""#

    /// The signature of a container: one entry per child, in order. Above the last level an entry
    /// is the child's own signature paired with the signature of its children, which is empty for a
    /// value that is not a container.
    private static func signature(of value: String, depth: Int) -> String {
        let entry = depth > 1
            ? "[\(leafSignature(of: elementVariable)),\(signature(of: elementVariable, depth: depth - 1))]"
            : leafSignature(of: elementVariable)
        return #"{"$map":{"input":\#(childValues(of: value)),"in":\#(entry)}}"#
    }

    /// A container's children as an array, and an empty array for anything else, so the `$map`
    /// over it never raises whatever the field holds now.
    private static func childValues(of value: String) -> String {
        let fields = #"{"$objectToArray":{"$cond":[{"$eq":[{"$type":\#(value)},"object"]},\#(value),{}]}}"#
        return #"{"$cond":[{"$isArray":\#(value)},\#(value),{"$map":{"input":\#(fields),"in":"$$this.v"}}]}"#
    }

    /// The `$type` name, and for a decimal or a zero double also its text, which is the only way
    /// to tell `1.0` from `1.00` and `0.0` from `-0.0`.
    private static func leafSignature(of value: String) -> String {
        let type = #"{"$type":\#(value)}"#
        let isZeroDouble = #"{"$and":[{"$eq":[\#(type),"double"]},{"$eq":[\#(value),0]}]}"#
        let needsText = #"{"$or":[{"$eq":[\#(type),"decimal"]},\#(isZeroDouble)]}"#
        let text = #"{"$convert":{"input":\#(value),"to":"string","onError":"","onNull":""}}"#
        return #"{"$cond":[\#(needsText),[\#(type),\#(text)],\#(type)]}"#
    }

    // MARK: - What the server should answer

    private static func expectedSignature(
        ofContainer value: MongoDocumentText.Value,
        depth: Int
    ) throws -> MongoDocumentText.Value {
        let entries = try children(of: value).map { child -> MongoDocumentText.Value in
            let leaf = try expectedLeafSignature(of: child)
            guard depth > 1 else { return leaf }
            let nested = MongoExtendedJsonType.isContainer(child)
                ? try expectedSignature(ofContainer: child, depth: depth - 1)
                : .array([])
            return .array([leaf, nested])
        }
        return .array(entries)
    }

    /// Every value but the document itself passes through here, so this is where a value the
    /// signature cannot describe is refused.
    private static func expectedLeafSignature(of value: MongoDocumentText.Value) throws -> MongoDocumentText.Value {
        guard let type = MongoExtendedJsonType.name(of: value) else { throw Refusal.unreadableValue }
        guard type != "javascriptWithScope" else { throw Refusal.codeWithScope }
        guard case .object(let members) = value, members.count == 1, let member = members.first,
              case .string(let text) = member.value else {
            return .string(type)
        }
        switch member.key {
        case "$numberDecimal":
            guard text != notANumberText else { throw Refusal.notANumber }
            return .array([.string(type), .string(text)])
        case "$numberDouble":
            guard text != notANumberText else { throw Refusal.notANumber }
            guard let number = Double(text), number == 0 else { return .string(type) }
            return .array([.string(type), .string(number.sign == .minus ? "-0" : "0")])
        default:
            return .string(type)
        }
    }

    /// How canonical Extended JSON writes every NaN, double or decimal, whatever its sign and payload.
    private static let notANumberText = "NaN"

    private static func children(of value: MongoDocumentText.Value) -> [MongoDocumentText.Value] {
        switch value {
        case .array(let elements):
            return elements
        case .object(let members) where MongoExtendedJsonType.name(of: value) == "object":
            return members.map(\.value)
        case .object, .string, .number, .literal:
            return []
        }
    }
}
