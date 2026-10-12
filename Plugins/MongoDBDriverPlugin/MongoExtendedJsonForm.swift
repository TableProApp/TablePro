//
//  MongoExtendedJsonForm.swift
//  MongoDBDriverPlugin
//

import Foundation
import os

/// The two spellings of a nested document or array: the one a grid cell shows, and the one a write
/// hands the shell.
///
/// A cell used to show the value rebuilt from Swift dictionaries, which had sorted its keys and
/// turned an ObjectId, a date, a decimal and a 64-bit integer into text or a bare number. Editing it
/// wrote those back as strings and doubles. The cell now shows the stored document's own Extended
/// JSON, in stored order, relaxed where that loses nothing: an int32 is a bare number, a double
/// always has a point or an exponent, a date inside 1970 to 9999 is ISO text with milliseconds, and
/// every other type keeps its wrapper. `$numberLong` stays wrapped, because the relaxed form of a
/// small 64-bit integer reads back as an int32.
enum MongoExtendedJsonForm {
    typealias Value = MongoDocumentText.Value
    typealias Member = MongoDocumentText.Member

    static let wrapperKeys: Set<String> = [
        "$oid", "$symbol", "$numberInt", "$numberLong", "$numberDouble", "$numberDecimal", "$binary",
        "$code", "$timestamp", "$regularExpression", "$dbPointer", "$date", "$minKey", "$maxKey",
        "$undefined", "$uuid", "$regex"
    ]

    /// The keys a wrapper may hold beside the one that opens it, in the legacy forms libbson reads.
    private static let companionKeys: [String: Set<String>] = [
        "$binary": ["$type"], "$code": ["$scope"], "$regex": ["$options"]
    ]

    /// An object that stands for one BSON value rather than an embedded document: it opens with a
    /// wrapper key and holds nothing that wrapper does not take. An object that opens with `$oid`
    /// and goes on to other members is a document, so its other members are written and checked
    /// like any document's rather than dropped with the wrapper.
    static func isWrapper(_ members: [Member]) -> Bool {
        guard let first = members.first, wrapperKeys.contains(first.key) else { return false }
        let allowed = companionKeys[first.key] ?? []
        var seen: Set<String> = [first.key]
        for member in members.dropFirst() {
            guard allowed.contains(member.key), seen.insert(member.key).inserted else { return false }
        }
        return true
    }

    // MARK: - Display

    static func display(_ canonical: Value) -> Value {
        switch canonical {
        case .object(let members):
            if let relaxed = relaxedScalar(members) { return relaxed }
            if isWrapper(members) { return canonical }
            return .object(members.map { Member(key: $0.key, value: display($0.value)) })
        case .array(let elements):
            return .array(elements.map(display))
        case .string, .number, .literal:
            return canonical
        }
    }

    private static func relaxedScalar(_ members: [Member]) -> Value? {
        guard members.count == 1, let only = members.first else { return nil }
        switch (only.key, only.value) {
        case ("$numberInt", .string(let digits)):
            return Int32(digits).map { .number(String($0)) }
        case ("$numberDouble", .string(let text)):
            return doubleText(text).map { .number($0) }
        case ("$date", .object(let inner)):
            return isoDateText(inner).map { .object([Member(key: "$date", value: .string($0))]) }
        default:
            return nil
        }
    }

    /// libbson writes a double with twenty significant digits, so 0.1 arrives as
    /// 0.10000000000000000555. The shortest text that reads back as the same double is shown, with a
    /// point or an exponent so it cannot be read back as an integer.
    private static func doubleText(_ canonical: String) -> String? {
        guard let value = Double(canonical), value.isFinite else { return nil }
        let shortest = value.description
        let isFloatingForm = shortest.contains(".") || shortest.contains("e") || shortest.contains("E")
        return isFloatingForm ? shortest : shortest + ".0"
    }

    /// The relaxed spec's range for an ISO date, and the only one `Date` formats without a sign.
    private static let isoDateMilliseconds: ClosedRange<Int64> = 0 ... 253_402_300_799_999

    private static let isoFormatter = OSAllocatedUnfairLock(uncheckedState: {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }())

    private static func isoDateText(_ inner: [Member]) -> String? {
        guard inner.count == 1, let only = inner.first, only.key == "$numberLong",
              case .string(let digits) = only.value,
              let milliseconds = Int64(digits), isoDateMilliseconds.contains(milliseconds) else {
            return nil
        }
        let seconds = Date(timeIntervalSince1970: TimeInterval(milliseconds / 1_000))
        let whole = isoFormatter.withLockUnchecked { $0.string(from: seconds) }
        guard whole.hasSuffix("Z") else { return nil }
        let fraction = String(format: ".%03lldZ", milliseconds % 1_000)
        return String(whole.dropLast()) + fraction
    }

    // MARK: - Shell

    /// The value with every number spelled so JavaScript cannot retype it, refused where the shell
    /// would store something other than what the text shows.
    ///
    /// A whole-number double such as 3.0 is a JavaScript integer, which the shell sends as an int32,
    /// and an integer past 2^53 is rounded, so both are wrapped. Other numbers stay bare and reach
    /// the server as the same int32, int64 or double. An object is a JavaScript object, which lists
    /// number-like keys first and reads `__proto__` as its prototype, so an object whose keys would
    /// not survive in the order written is refused rather than stored in another order.
    static func shellValue(_ display: Value, field: String) throws -> Value {
        switch display {
        case .number(let text):
            return try shellNumber(text, field: field)
        case .object(let members):
            if isWrapper(members) { return try shellWrapper(members, field: field) }
            guard MongoShellKeyOrder.survives(members.map(\.key)) else {
                throw MongoDBWriteRefusal.reorderedByTheShell(field: field)
            }
            return .object(try members.map { Member(key: $0.key, value: try shellValue($0.value, field: field)) })
        case .array(let elements):
            return .array(try elements.map { try shellValue($0, field: field) })
        case .string, .literal:
            return display
        }
    }

    /// A wrapper as the shell has to be handed it to serialize it back unchanged.
    ///
    /// The shell's serializer spells every JavaScript number as a wrapper of its own, which libbson
    /// then refuses inside a timestamp or a boundary key, where it reads a bare number. Those are
    /// handed over as the shell's own `Timestamp`, `MinKey` and `MaxKey`, which serialize with
    /// their numbers bare. A `$scope` is a document, so it is spelled like any other. Every other
    /// wrapper holds only strings, which reach libbson as written.
    private static func shellWrapper(_ members: [Member], field: String) throws -> Value {
        if let expression = shellExpression(members) {
            return .literal(expression)
        }
        return .object(try members.map { member in
            guard member.key == "$scope" else { return member }
            return Member(key: member.key, value: try shellValue(member.value, field: field))
        })
    }

    private static func shellExpression(_ members: [Member]) -> String? {
        guard members.count == 1, let only = members.first else { return nil }
        switch (only.key, only.value) {
        case ("$minKey", .number("1")):
            return "MinKey"
        case ("$maxKey", .number("1")):
            return "MaxKey"
        case ("$timestamp", .object(let parts)):
            let numbers = Dictionary(parts.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
            guard parts.count == 2, case .number(let seconds) = numbers["t"], case .number(let increment) = numbers["i"],
                  let time = UInt32(seconds), let ordinal = UInt32(increment) else {
                return nil
            }
            return "Timestamp(\(time), \(ordinal))"
        default:
            return nil
        }
    }

    private static let largestExactInteger: UInt64 = 1 << 53

    private static func shellNumber(_ text: String, field: String) throws -> Value {
        let isFloatingForm = text.contains(".") || text.contains("e") || text.contains("E")
        if isFloatingForm {
            guard let value = Double(text), value.isFinite else {
                throw MongoDBWriteRefusal.unreadableJSON(field: field)
            }
            let staysDouble = value.rounded(.towardZero) != value
            return staysDouble ? .number(text) : wrapped("$numberDouble", text)
        }
        guard let integer = Int64(text) else { throw MongoDBWriteRefusal.integerTooLarge(field: field) }
        return integer.magnitude > largestExactInteger ? wrapped("$numberLong", text) : .number(text)
    }

    private static func wrapped(_ key: String, _ text: String) -> Value {
        .object([Member(key: key, value: .string(text))])
    }
}

/// Whether a JavaScript object keeps its keys in the order they were written.
///
/// JavaScript lists array-index keys first, in ascending order, and treats `__proto__` as the
/// prototype rather than as a key, so neither kind of name reaches the server where it was written.
enum MongoShellKeyOrder {
    static func survives(_ keys: [String]) -> Bool {
        guard !keys.contains("__proto__") else { return false }
        let moved = keys.filter(MongoDBCollectionDDL.isReorderedByTheShell)
        guard !moved.isEmpty else { return true }
        let shellOrder = moved.sorted(by: isNumericallyBefore) + keys.filter { !MongoDBCollectionDDL.isReorderedByTheShell($0) }
        return shellOrder == keys
    }

    private static func isNumericallyBefore(_ lhs: String, _ rhs: String) -> Bool {
        let lhsLength = (lhs as NSString).length
        let rhsLength = (rhs as NSString).length
        return lhsLength == rhsLength ? lhs < rhs : lhsLength < rhsLength
    }
}

extension MongoDocumentText.Value {
    var isContainer: Bool {
        switch self {
        case .object, .array: return true
        case .string, .number, .literal: return false
        }
    }

    /// Whether any object in the value, at any depth, has a key that is the empty string.
    var holdsEmptyKey: Bool {
        switch self {
        case .object(let members): return members.contains { $0.key.isEmpty || $0.value.holdsEmptyKey }
        case .array(let elements): return elements.contains { $0.holdsEmptyKey }
        case .string, .number, .literal: return false
        }
    }
}
