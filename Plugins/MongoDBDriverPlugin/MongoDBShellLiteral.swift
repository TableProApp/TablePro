import Foundation

/// Shell source for a canonical Extended JSON value, which TablePro's shell and mongosh both read
/// back as the BSON the server holds.
///
/// A bare number in a script is whatever the shell makes of a JavaScript `Number`, so relaxed
/// Extended JSON cannot carry a type: `NumberLong(1)` came back an Int32, a whole Double came back
/// an Int32, and `9007199254740993` came back `9007199254740992`. Every value a bare number cannot
/// carry is written through the constructor that names its type in both shells. A canonical
/// wrapper written as an object reaches mongosh as a document, so a regular expression in a
/// `$match` became an unknown `$regularExpression` operator there. Only a value mongosh has no way
/// to write at all, a DBPointer, `undefined` or a date past JavaScript's range, keeps its wrapper,
/// which TablePro's shell sends to the server as it is.
enum MongoDBShellLiteral {
    private static let millisecondsPerDay: Int64 = 86_400_000
    private static let javaScriptDateLimit: Int64 = 8_640_000_000_000_000
    private static let decimalPattern = #"^([+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?|NaN|-?Infinity)$"#
    private static let jsonNumberPattern = #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#

    static func render(_ canonicalJson: String) -> String {
        let trimmed = canonicalJson.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") {
            let elements = MongoScriptJson.topLevelElements(trimmed).map(render)
            return elements.isEmpty ? "[ ]" : "[ \(elements.joined(separator: ", ")) ]"
        }
        guard trimmed.hasPrefix("{") else { return scalar(trimmed) }
        let members = MongoScriptJson.members(of: trimmed)
        return typedValue(members)
            ?? MongoDBJsonLayout.shellObject(members.map { (key: $0.key, value: render($0.value)) })
    }

    /// A string is written again through the plugin's own escaper, because the server's text can
    /// hold a line separator that libbson leaves raw. Anything that is not a string, a number,
    /// `true`, `false` or `null` is written as the string it spells, so no text reaches the
    /// statement outside a literal.
    private static func scalar(_ token: String) -> String {
        if token.hasPrefix("\"") {
            return MongoScriptJson.jsonString(MongoScriptJson.decodedString(token) ?? token)
        }
        let isLiteral = ["true", "false", "null"].contains(token)
            || token.range(of: jsonNumberPattern, options: .regularExpression) != nil
        return isLiteral ? token : MongoScriptJson.jsonString(token)
    }

    private static func typedValue(_ members: [(key: String, value: String)]) -> String? {
        guard let first = members.first else { return nil }
        if members.count == 2, first.key == "$code", members[1].key == "$scope" {
            return code(first.value, scope: members[1].value)
        }
        guard members.count == 1 else { return nil }
        let text = MongoScriptJson.decodedString(first.value)
        switch first.key {
        case "$numberInt": return text.flatMap { Int32($0) }.map { String($0) }
        case "$numberLong": return text.flatMap { Int64($0) }.map { "NumberLong(\"\($0)\")" }
        case "$numberDouble": return text.flatMap(double)
        case "$numberDecimal":
            return text.map { decimal($0) ?? wrapper(first.key, MongoScriptJson.jsonString($0)) }
        case "$oid": return text.map { "ObjectId(\(MongoScriptJson.jsonString($0)))" }
        case "$date": return millis(first.value).map(date)
        case "$binary": return binary(first.value)
        case "$timestamp": return timestamp(first.value)
        case "$regularExpression": return regularExpression(first.value)
        case "$symbol": return text.map { "BSONSymbol(\(MongoScriptJson.jsonString($0)))" }
        case "$minKey": return "MinKey()"
        case "$maxKey": return "MaxKey()"
        case "$code": return code(first.value, scope: nil)
        default: return nil
        }
    }

    /// A fraction reads back as a Double on its own. A whole value needs `Double(...)`, or the
    /// shell stores it as an integer.
    private static func double(_ text: String) -> String? {
        if ["Infinity", "-Infinity", "NaN"].contains(text) { return text }
        guard let value = Double(text), value.isFinite else { return nil }
        return value.rounded(.towardZero) == value ? "Double(\(value))" : "\(value)"
    }

    private static func decimal(_ text: String) -> String? {
        guard text.range(of: decimalPattern, options: .regularExpression) != nil else { return nil }
        return "NumberDecimal(\(MongoScriptJson.jsonString(text)))"
    }

    /// `ISODate` spells a four-digit year only, in mongosh as well, so any other date is written as
    /// the instant it is, as far as a JavaScript `Date` reaches.
    private static func date(_ millis: Int64) -> String {
        if let text = isoDate(millis) { return "ISODate(\"\(text)\")" }
        guard (-javaScriptDateLimit ... javaScriptDateLimit).contains(millis) else { return dateWrapper(millis) }
        return "new Date(\(millis))"
    }

    private static func regularExpression(_ valueJson: String) -> String? {
        guard let pattern = MongoScriptJson.member(of: valueJson, key: "pattern").flatMap(MongoScriptJson.decodedString),
              let options = MongoScriptJson.member(of: valueJson, key: "options").flatMap(MongoScriptJson.decodedString)
        else {
            return nil
        }
        return "BSONRegExp(\(MongoScriptJson.jsonString(pattern)), \(MongoScriptJson.jsonString(options)))"
    }

    private static func millis(_ dateJson: String) -> Int64? {
        MongoScriptJson.member(of: dateJson, key: "$numberLong")
            .flatMap(MongoScriptJson.decodedString)
            .flatMap { Int64($0) }
    }

    private static func dateWrapper(_ millis: Int64) -> String {
        wrapper("$date", wrapper("$numberLong", MongoScriptJson.jsonString(String(millis))))
    }

    /// A canonical wrapper rebuilt from the value it was read as, never copied from the server's text.
    private static func wrapper(_ key: String, _ value: String) -> String {
        MongoDBJsonLayout.shellObject([(key: key, value: value)])
    }

    private static func binary(_ valueJson: String) -> String? {
        guard let base64 = MongoScriptJson.member(of: valueJson, key: "base64").flatMap(MongoScriptJson.decodedString),
              let subtype = MongoScriptJson.member(of: valueJson, key: "subType")
                  .flatMap(MongoScriptJson.decodedString)
                  .flatMap({ UInt8($0, radix: 16) }) else {
            return nil
        }
        return "BinData(\(subtype), \(MongoScriptJson.jsonString(base64)))"
    }

    private static func timestamp(_ valueJson: String) -> String? {
        guard let seconds = MongoScriptJson.member(of: valueJson, key: "t").flatMap({ UInt32($0) }),
              let increment = MongoScriptJson.member(of: valueJson, key: "i").flatMap({ UInt32($0) }) else {
            return nil
        }
        return "Timestamp(\(seconds), \(increment))"
    }

    private static func code(_ codeJson: String, scope scopeJson: String?) -> String? {
        guard let source = MongoScriptJson.decodedString(codeJson) else { return nil }
        let arguments = [MongoScriptJson.jsonString(source)] + (scopeJson.map { [render($0)] } ?? [])
        return "Code(\(arguments.joined(separator: ", ")))"
    }

    /// The instant in the proleptic Gregorian calendar JavaScript's `Date` counts in, for the years
    /// 1 through 9999 that a four-digit `ISODate` string can spell.
    private static func isoDate(_ millis: Int64) -> String? {
        var days = millis / millisecondsPerDay
        var dayMillis = millis % millisecondsPerDay
        if dayMillis < 0 {
            days -= 1
            dayMillis += millisecondsPerDay
        }
        let civil = civilDate(daysSinceEpoch: days)
        guard (1 ... 9_999).contains(civil.year) else { return nil }
        return String(
            format: "%04lld-%02lld-%02lldT%02lld:%02lld:%02lld.%03lldZ",
            civil.year, civil.month, civil.day,
            dayMillis / 3_600_000, dayMillis / 60_000 % 60, dayMillis / 1_000 % 60, dayMillis % 1_000
        )
    }

    /// Howard Hinnant's `civil_from_days`, which has no calendar reform in it, unlike Foundation's
    /// Gregorian calendar, which switches to the Julian one before October 1582.
    private static func civilDate(daysSinceEpoch: Int64) -> (year: Int64, month: Int64, day: Int64) {
        let shifted = daysSinceEpoch + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        return (year: yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month: month, day: day)
    }
}
