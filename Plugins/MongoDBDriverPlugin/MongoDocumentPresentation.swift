import Foundation

/// A stored document as text a person edits, which reads back as exactly the same document.
///
/// Canonical Extended JSON is exact and unreadable: every number is a string in a wrapper. Relaxed
/// Extended JSON reads well and is not exact: a 64-bit integer small enough for 32 bits comes back
/// as a 32-bit one, and libbson cannot read back the date text it writes for years past 9999.
/// So each value is written the relaxed way only where that reads back as the same type and value,
/// and keeps its canonical wrapper everywhere else.
enum MongoDocumentPresentation {
    static func editableText(_ document: MongoDocumentText) -> String {
        var output = ""
        write(readable(.object(document.members)), into: &output, indent: 0)
        return output
    }

    /// The canonical form, indented, for a document whose readable form does not read back as the
    /// same document.
    static func prettyCanonical(_ document: MongoDocumentText) -> String {
        var output = ""
        write(.object(document.members), into: &output, indent: 0)
        return output
    }

    static func readable(_ value: MongoDocumentText.Value) -> MongoDocumentText.Value {
        switch value {
        case .object(let members):
            if let relaxed = relaxedScalar(members) { return relaxed }
            if members.first?.key.hasPrefix("$") == true { return value }
            return .object(members.map { MongoDocumentText.Member(key: $0.key, value: readable($0.value)) })
        case .array(let elements):
            return .array(elements.map(readable))
        case .string, .number, .literal:
            return value
        }
    }

    private static func relaxedScalar(_ members: [MongoDocumentText.Member]) -> MongoDocumentText.Value? {
        guard members.count == 1, let member = members.first else { return nil }
        switch (member.key, member.value) {
        case ("$numberInt", .string(let text)):
            guard Int32(text) != nil else { return nil }
            return .number(text)
        case ("$numberLong", .string(let text)):
            guard let value = Int64(text), Int32(exactly: value) == nil else { return nil }
            return .number(text)
        case ("$numberDouble", .string(let text)):
            guard let value = Double(text), value.isFinite else { return nil }
            let shortest = value.description
            guard shortest.rangeOfCharacter(from: fractionMarkers) != nil,
                  Double(shortest)?.bitPattern == value.bitPattern else { return nil }
            return .number(shortest)
        case ("$date", .object(let wrapped)):
            guard wrapped.count == 1, let millis = wrapped.first,
                  millis.key == "$numberLong", case .string(let text) = millis.value,
                  let milliseconds = Int64(text),
                  let iso = isoDate(milliseconds: milliseconds) else { return nil }
            return .object([MongoDocumentText.Member(key: "$date", value: .string(iso))])
        default:
            return nil
        }
    }

    private static let fractionMarkers = CharacterSet(charactersIn: ".eE")

    /// The relaxed form only covers 1970 through 9999, which is the range whose ISO text libbson
    /// both writes and reads.
    private static let latestRelaxedDate: Int64 = 253_402_300_799_999

    static func isoDate(milliseconds: Int64) -> String? {
        guard milliseconds >= 0, milliseconds <= latestRelaxedDate else { return nil }
        let seconds = milliseconds / 1_000
        let fraction = milliseconds % 1_000
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day,
              let hour = parts.hour, let minute = parts.minute, let second = parts.second else { return nil }
        let base = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", year, month, day, hour, minute, second)
        return fraction == 0 ? base + "Z" : base + String(format: ".%03lldZ", fraction)
    }

    private static func write(_ shown: MongoDocumentText.Value, into output: inout String, indent: Int) {
        switch shown {
        case .object(let members) where members.isEmpty:
            output += "{}"
        case .array(let elements) where elements.isEmpty:
            output += "[]"
        case .object(let members) where isInlineWrapper(members):
            output += shown.compactText
        case .object(let members):
            output += "{\n"
            for (index, member) in members.enumerated() {
                output += String(repeating: "  ", count: indent + 1)
                output += MongoDocumentText.quoted(member.key) + ": "
                write(member.value, into: &output, indent: indent + 1)
                output += index == members.count - 1 ? "\n" : ",\n"
            }
            output += String(repeating: "  ", count: indent) + "}"
        case .array(let elements):
            output += "[\n"
            for (index, element) in elements.enumerated() {
                output += String(repeating: "  ", count: indent + 1)
                write(element, into: &output, indent: indent + 1)
                output += index == elements.count - 1 ? "\n" : ",\n"
            }
            output += String(repeating: "  ", count: indent) + "]"
        case .string, .number, .literal:
            output += shown.compactText
        }
    }

    /// `{"$oid": "…"}` is one value, so it stays on one line.
    private static func isInlineWrapper(_ members: [MongoDocumentText.Member]) -> Bool {
        guard let first = members.first, first.key.hasPrefix("$") else { return false }
        return members.allSatisfy { member in
            switch member.value {
            case .string, .number, .literal: return true
            case .object(let inner): return inner.count <= 2
            case .array: return false
            }
        }
    }
}
