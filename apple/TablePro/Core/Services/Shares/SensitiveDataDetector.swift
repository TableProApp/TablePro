//
//  SensitiveDataDetector.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// What a column's name says it holds. Every TablePro app lists the same terms in the same order.
internal enum SensitiveNameKind: CaseIterable, Equatable, Sendable {
    case email
    case phone
    case secret
    case nationalID
    case cardOrAccount
    case address
    case birthDate
    case ipAddress
    case personName

    var terms: [String] {
        switch self {
        case .email: ["email", "mail"]
        case .phone: ["phone", "mobile", "tel", "telephone", "fax", "msisdn"]
        case .secret:
            ["password", "passwd", "pwd", "secret", "token", "apikey", "accesskey", "privatekey", "credential"]
        case .nationalID: ["ssn", "socialsecurity", "nationalid", "passport", "taxid", "tin"]
        case .cardOrAccount:
            ["creditcard", "cardnumber", "ccnumber", "pan", "iban", "accountnumber", "routingnumber"]
        case .address: ["address", "street", "zip", "zipcode", "postcode", "postal"]
        case .birthDate: ["dob", "birthdate", "dateofbirth", "birthday"]
        case .ipAddress: ["ip", "ipaddress", "ipv4", "ipv6"]
        case .personName: ["firstname", "lastname", "fullname", "surname", "givenname"]
        }
    }

    var style: MaskingStyle {
        switch self {
        case .email: .email
        case .phone, .nationalID, .cardOrAccount: .lastFour
        case .secret, .address, .birthDate, .personName: .full
        case .ipAddress: .hash
        }
    }

    var displayName: String {
        switch self {
        case .email: String(localized: "email address")
        case .phone: String(localized: "phone number")
        case .secret: String(localized: "password or secret")
        case .nationalID: String(localized: "ID number")
        case .cardOrAccount: String(localized: "card or account number")
        case .address: String(localized: "postal address")
        case .birthDate: String(localized: "date of birth")
        case .ipAddress: String(localized: "IP address")
        case .personName: String(localized: "person's name")
        }
    }
}

// What a column's values look like, in the order that decides between two kinds.
internal enum SensitiveValueKind: CaseIterable, Equatable, Sendable {
    case card
    case iban
    case jsonWebToken
    case apiKey
    case email
    case phone
    case ipAddress

    // One such value flags the column; the others need at least half of its values.
    var flagsOnAnyValue: Bool {
        switch self {
        case .card, .iban, .jsonWebToken, .apiKey: true
        case .email, .phone, .ipAddress: false
        }
    }

    var style: MaskingStyle {
        switch self {
        case .card, .iban, .phone: .lastFour
        case .jsonWebToken, .apiKey: .full
        case .email: .email
        case .ipAddress: .hash
        }
    }

    var displayName: String {
        switch self {
        case .card: String(localized: "card number")
        case .iban: "IBAN"
        case .jsonWebToken: String(localized: "JSON Web Token")
        case .apiKey: String(localized: "API key")
        case .email: String(localized: "email address")
        case .phone: String(localized: "phone number")
        case .ipAddress: String(localized: "IP address")
        }
    }

    // The kinds a quoted literal in the SQL can show.
    static let inSQL: [SensitiveValueKind] = [.card, .iban, .jsonWebToken, .apiKey, .email, .phone]
}

internal enum SensitiveDetection: Equatable, Sendable {
    case name(SensitiveNameKind)
    case values(SensitiveValueKind)

    var style: MaskingStyle {
        switch self {
        case .name(let kind): kind.style
        case .values(let kind): kind.style
        }
    }

    var displayName: String {
        switch self {
        case .name(let kind): kind.displayName
        case .values(let kind): kind.displayName
        }
    }
}

// Finds what looks like personal data before a share leaves the machine (PLAN-MASKING 8.3 and 8.3.1). The Rust core
// runs the same rules, and DETECTOR-FIXTURES.md pins both to one table.
internal enum SensitiveDataDetector {
    // MARK: - Column names

    // In table order, so a tie goes to the earlier term.
    private static let nameTerms: [(term: String, kind: SensitiveNameKind)] = SensitiveNameKind.allCases.flatMap { kind in
        kind.terms.map { ($0, kind) }
    }

    static func nameKind(_ column: String) -> SensitiveNameKind? {
        let found = longestTerm(in: words(in: column), terms: nameTerms.map(\.term), singleWord: ["mail"])
        return found.map { nameTerms[$0].kind }
    }

    // The index of the term that equals one word or several consecutive words joined, never part of a word: the one
    // covering the most words, a tie going to the earlier term.
    static func longestTerm(in words: [String], terms: [String], singleWord: Set<String> = []) -> Int? {
        let longest = terms.map(\.count).max() ?? 0
        var best: (span: Int, index: Int)?
        for start in words.indices {
            var joined = ""
            for end in start..<words.count {
                joined += words[end]
                guard joined.count <= longest else { break }
                let span = end - start + 1
                guard let index = terms.firstIndex(of: joined), span == 1 || !singleWord.contains(joined) else { continue }
                if let current = best, current.span > span || (current.span == span && current.index <= index) {
                    continue
                }
                best = (span, index)
            }
        }
        return best?.index
    }

    // Split on `_ - . space`, where a lower-case letter meets an upper-case one, and where letters meet digits.
    static func words(in name: String) -> [String] {
        var words: [String] = []
        var current = String.UnicodeScalarView()
        var previous: Unicode.Scalar?
        func flush() {
            if !current.isEmpty {
                words.append(String(current).lowercased())
            }
            current = String.UnicodeScalarView()
        }
        for scalar in name.unicodeScalars {
            if scalar == "_" || scalar == "-" || scalar == "." || scalar == " " {
                flush()
                previous = nil
                continue
            }
            if let previous, isBoundary(previous, scalar) {
                flush()
            }
            current.append(scalar)
            previous = scalar
        }
        flush()
        return words
    }

    private static func isBoundary(_ previous: Unicode.Scalar, _ next: Unicode.Scalar) -> Bool {
        if previous.properties.isLowercase, next.properties.isUppercase { return true }
        let previousIsDigit = isDigit(previous)
        let nextIsDigit = isDigit(next)
        return (previousIsDigit && next.properties.isAlphabetic) || (nextIsDigit && previous.properties.isAlphabetic)
    }

    // MARK: - Column types

    private static let nonTextBaseType = try? NSRegularExpression(
        pattern: "\\A(?:u?int[0-9]*|tinyint|smallint|mediumint|bigint|integer|serial|smallserial|bigserial|numeric"
            + "|decimal[0-9]*|number|real|float[0-9]*|double|money|smallmoney|bool|boolean|bit|date[0-9]*|datetime[0-9]*"
            + "|smalldatetime|datetimeoffset|time|timetz|timestamp|timestamptz|interval|year|uuid|uniqueidentifier)"
            + "(?: .*)?\\z"
    )

    // Value patterns run only where a value can be free text; an unknown type can.
    static func isTextLike(_ rawType: String?) -> Bool {
        guard let rawType, let expression = nonTextBaseType else { return true }
        let base = MaskingPolicy.baseTypeName(rawType).lowercased()
        guard !base.isEmpty else { return true }
        return !hasMatch(expression, base)
    }

    // MARK: - Values

    // Nil too once the caller's task is cancelled, which the caller checks.
    static func valueKind(of values: some Sequence<PluginCellValue>) -> SensitiveValueKind? {
        var nonNull = 0
        var read = 0
        var flagged: SensitiveValueKind?
        var counts: [SensitiveValueKind: Int] = [:]
        for value in values {
            read += 1
            if read % 256 == 0, Task.isCancelled { return nil }
            let text: String
            switch value {
            case .null:
                continue
            case .bytes:
                nonNull += 1
                continue
            case .text(let string):
                nonNull += 1
                text = string
            }
            for kind in SensitiveValueKind.allCases where kind.flagsOnAnyValue {
                if let flagged, flagged.order <= kind.order { break }
                if matches(kind, text) {
                    flagged = kind
                    break
                }
            }
            if flagged == .card { return .card }
            guard flagged == nil else { continue }
            for kind in SensitiveValueKind.allCases where !kind.flagsOnAnyValue && matches(kind, text) {
                counts[kind, default: 0] += 1
            }
        }
        if let flagged { return flagged }
        guard nonNull > 0 else { return nil }
        return SensitiveValueKind.allCases.first { !$0.flagsOnAnyValue && counts[$0, default: 0] * 2 >= nonNull }
    }

    static func matches(_ kind: SensitiveValueKind, _ text: String) -> Bool {
        switch kind {
        case .card: isCardNumber(text)
        case .iban: isIBAN(text)
        case .jsonWebToken: text.hasPrefix("eyJ") && hasMatch(jsonWebToken, text)
        case .apiKey: mayHoldAPIKey(text) && hasMatch(apiKey, text)
        case .email: isEmail(text)
        case .phone: isPhoneNumber(text)
        case .ipAddress: isIPv4(text) || isIPv6(text)
        }
    }

    private static let jsonWebToken = try? NSRegularExpression(
        pattern: "\\AeyJ[A-Za-z0-9_-]+\\.eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\z"
    )
    private static let apiKey = try? NSRegularExpression(
        pattern: "AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{36,}|xox[abprs]-|sk_live_|AIza[0-9A-Za-z_-]{35}"
    )
    private static let ibanShape = try? NSRegularExpression(pattern: "\\A[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}\\z")

    // `\A[^\s@]+@[^\s@]+\.[^\s@]+\z` with `\s` as White_Space, in one pass: ICU backtracks over a long domain that
    // never matches. One `@` after at least one scalar, and a dot in the domain with a scalar on each side.
    static func isEmail(_ text: String) -> Bool {
        var local = 0
        var seenAt = false
        var domain = 0
        var dotWaitsForScalar = false
        var hasInnerDot = false
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace { return false }
            if scalar == "@" {
                guard !seenAt, local > 0 else { return false }
                seenAt = true
                continue
            }
            guard seenAt else {
                local += 1
                continue
            }
            if dotWaitsForScalar { hasInnerDot = true }
            if scalar == ".", domain > 0 { dotWaitsForScalar = true }
            domain += 1
        }
        return seenAt && hasInnerDot
    }

    static func isCardNumber(_ text: String) -> Bool {
        var digits: [UInt8] = []
        digits.reserveCapacity(19)
        for byte in text.utf8 {
            switch byte {
            case 0x30...0x39:
                digits.append(byte - 0x30)
                guard digits.count <= 19 else { return false }
            case 0x20, 0x2D:
                continue
            default:
                return false
            }
        }
        guard digits.count >= 13 else { return false }
        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() {
            var value = Int(digit)
            if offset % 2 == 1 {
                value *= 2
                if value > 9 { value -= 9 }
            }
            sum += value
        }
        return sum % 10 == 0
    }

    static func isIBAN(_ text: String) -> Bool {
        guard let first = text.utf8.first(where: { $0 != 0x20 }), (0x41...0x5A).contains(first) else { return false }
        let compact = String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 != " " }))
        guard hasMatch(ibanShape, compact) else { return false }
        let bytes = Array(compact.utf8)
        var remainder = 0
        for byte in bytes[4...] + bytes[..<4] {
            if byte >= 0x41 {
                remainder = (remainder * 100 + Int(byte - 0x41 + 10)) % 97
            } else {
                remainder = (remainder * 10 + Int(byte - 0x30)) % 97
            }
        }
        return remainder == 1
    }

    static func isPhoneNumber(_ text: String) -> Bool {
        var digits = 0
        var hasSeparator = false
        for (offset, byte) in text.utf8.enumerated() {
            switch byte {
            case 0x30...0x39:
                digits += 1
            case 0x2B where offset == 0:
                hasSeparator = true
            case 0x28, 0x29, 0x20, 0x2E, 0x2D:
                hasSeparator = true
            default:
                return false
            }
        }
        guard (7...15).contains(digits), hasSeparator else { return false }
        return !isIPv4(text) && !startsWithISODate(text) && !isPlainDecimal(text)
    }

    // `^[0-9]{4}-[0-9]{2}-[0-9]{2}`
    private static func startsWithISODate(_ text: String) -> Bool {
        let bytes = Array(text.utf8.prefix(10))
        guard bytes.count == 10 else { return false }
        return bytes.indices.allSatisfy { offset in
            offset == 4 || offset == 7 ? bytes[offset] == 0x2D : isDigit(bytes[offset])
        }
    }

    // `^[+-]?[0-9]+\.[0-9]+$`
    private static func isPlainDecimal(_ text: String) -> Bool {
        var bytes = Array(text.utf8)
        if let sign = bytes.first, sign == 0x2B || sign == 0x2D {
            bytes.removeFirst()
        }
        guard let dot = bytes.firstIndex(of: 0x2E) else { return false }
        let whole = bytes[..<dot]
        let fraction = bytes[(dot + 1)...]
        return !whole.isEmpty && !fraction.isEmpty && whole.allSatisfy(isDigit) && fraction.allSatisfy(isDigit)
    }

    // One of the key prefixes appears, so most values skip the regex.
    private static func mayHoldAPIKey(_ text: String) -> Bool {
        var text = text
        return text.withUTF8 { bytes in
            guard bytes.count >= 4 else { return false }
            for index in 0..<(bytes.count - 3) {
                let next = (bytes[index + 1], bytes[index + 2], bytes[index + 3])
                switch bytes[index] {
                case UInt8(ascii: "A") where next == (0x4B, 0x49, 0x41) || next == (0x49, 0x7A, 0x61): return true
                case UInt8(ascii: "g") where next.0 == UInt8(ascii: "h") && next.2 == UInt8(ascii: "_"): return true
                case UInt8(ascii: "x") where next.0 == UInt8(ascii: "o") && next.1 == UInt8(ascii: "x"): return true
                case UInt8(ascii: "s") where next == (0x6B, 0x5F, 0x6C): return true
                default: continue
                }
            }
            return false
        }
    }

    static func isIPv4(_ text: String) -> Bool {
        var parser = AddressParser(text)
        return parser.readIPv4() && parser.isAtEnd
    }

    static func isIPv6(_ text: String) -> Bool {
        var parser = AddressParser(text)
        return parser.readIPv6() && parser.isAtEnd
    }

    // MARK: - SQL

    struct PersonalDataHit: Equatable, Sendable {
        let kind: SensitiveValueKind
        // The line the literal starts on, from 1; CR, LF and CRLF each end a line.
        let line: Int
    }

    // Each literal takes the first kind it shows; each kind once per line, by line.
    static func personalDataHits(inSQL sql: String) -> [PersonalDataHit] {
        var hits: [PersonalDataHit] = []
        for literal in quotedLiterals(in: sql) {
            guard let kind = SensitiveValueKind.inSQL.first(where: { matches($0, literal.text) }) else { continue }
            let hit = PersonalDataHit(kind: kind, line: literal.line)
            if !hits.contains(hit) {
                hits.append(hit)
            }
        }
        return hits.sorted { ($0.line, $0.kind.order) < ($1.line, $1.kind.order) }
    }

    // The kinds the SQL's literals show, in table order.
    static func personalData(inSQL sql: String) -> [SensitiveValueKind] {
        let found = Set(personalDataHits(inSQL: sql).map(\.kind))
        return SensitiveValueKind.inSQL.filter(found.contains)
    }

    // Closed single-quoted literals, `''` read as a quote inside one. Double-quoted text is a name, `--` to the end of
    // the line and `/* */` are comments, all skipped, so an apostrophe there opens nothing; a literal left open is not
    // read.
    static func quotedLiterals(in sql: String) -> [(line: Int, text: String)] {
        var literals: [(line: Int, text: String)] = []
        let scalars = Array(sql.unicodeScalars)
        var line = 1
        var index = 0
        func advance() {
            let scalar = scalars[index]
            index += 1
            let endsLine = scalar == "\n" || (scalar == "\r" && (index == scalars.count || scalars[index] != "\n"))
            if endsLine { line += 1 }
        }
        func next(is scalar: Unicode.Scalar) -> Bool {
            index < scalars.count && scalars[index] == scalar
        }
        while index < scalars.count {
            let opener = scalars[index]
            let startLine = line
            advance()
            if opener == "-", next(is: "-") {
                while index < scalars.count, scalars[index] != "\n", scalars[index] != "\r" {
                    advance()
                }
            } else if opener == "/", next(is: "*") {
                advance()
                while index < scalars.count {
                    let closes = scalars[index] == "*" && index + 1 < scalars.count && scalars[index + 1] == "/"
                    advance()
                    if closes {
                        advance()
                        break
                    }
                }
            } else if opener == "\"" {
                while index < scalars.count {
                    let closes = scalars[index] == "\""
                    advance()
                    if closes { break }
                }
            } else if opener == "'" {
                var literal: [Unicode.Scalar] = []
                var closed = false
                while index < scalars.count {
                    let scalar = scalars[index]
                    advance()
                    guard scalar == "'" else {
                        literal.append(scalar)
                        continue
                    }
                    if index < scalars.count, scalars[index] == "'" {
                        literal.append("'")
                        advance()
                    } else {
                        closed = true
                        break
                    }
                }
                if closed {
                    literals.append((startLine, String(String.UnicodeScalarView(literal))))
                }
            }
        }
        return literals
    }

    // MARK: - A result

    // Each window is a count of leading rows, read on its own with its own thresholds; a column any window flags is
    // flagged, with the first kind in table order. Nil once the caller's task is cancelled. Columns the connection's
    // rules mask get nothing: their values are gone.
    static func detections(in source: ShareResultSource, windows: [Int]) -> [Int: SensitiveDetection]? {
        var detections: [Int: SensitiveDetection] = [:]
        let counts = Set(windows.map { min(max(0, $0), source.rows.count) }).filter { $0 > 0 }
        for index in source.columns.indices where !source.masks.isMasked(index) {
            if Task.isCancelled { return nil }
            if let kind = nameKind(source.columns[index]) {
                detections[index] = .name(kind)
                continue
            }
            let rawType = source.columnTypes.indices.contains(index) ? source.columnTypes[index].rawType : nil
            guard isTextLike(rawType) else { continue }
            var found: SensitiveValueKind?
            for count in counts {
                let values = source.rows.prefix(count).lazy.map { $0.indices.contains(index) ? $0[index] : .null }
                let kind = valueKind(of: values)
                if Task.isCancelled { return nil }
                if let kind, found.map({ kind.order < $0.order }) ?? true {
                    found = kind
                }
            }
            if let found {
                detections[index] = .values(found)
            }
        }
        return detections
    }

    // MARK: - Helpers

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar)
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
    }

    private static func hasMatch(_ expression: NSRegularExpression?, _ text: String) -> Bool {
        guard let expression else { return false }
        return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

private extension SensitiveValueKind {
    var order: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }
}

// Rust's `std::net` address parser, step for step, so both apps agree on every edge.
private struct AddressParser {
    private let bytes: [UInt8]
    private var position = 0

    init(_ text: String) {
        bytes = Array(text.utf8)
    }

    var isAtEnd: Bool {
        position == bytes.count
    }

    mutating func readIPv4() -> Bool {
        let start = position
        for part in 0..<4 {
            guard part == 0 || read(0x2E), let value = readNumber(radix: 10, maxDigits: 3, allowsZeroPrefix: false),
                  value <= 255
            else {
                position = start
                return false
            }
        }
        return true
    }

    mutating func readIPv6() -> Bool {
        let start = position
        let head = readGroups(limit: 8)
        if head.count == 8 { return true }
        guard !head.endsInIPv4, read(0x3A), read(0x3A) else {
            position = start
            return false
        }
        _ = readGroups(limit: 8 - (head.count + 1))
        return true
    }

    private mutating func readGroups(limit: Int) -> (count: Int, endsInIPv4: Bool) {
        for index in 0..<limit {
            if index < limit - 1 {
                let saved = position
                if index == 0 || read(0x3A), readIPv4() {
                    return (index + 2, true)
                }
                position = saved
            }
            let saved = position
            guard index == 0 || read(0x3A), readNumber(radix: 16, maxDigits: 4, allowsZeroPrefix: true) != nil else {
                position = saved
                return (index, false)
            }
        }
        return (limit, false)
    }

    private mutating func readNumber(radix: Int, maxDigits: Int, allowsZeroPrefix: Bool) -> Int? {
        let start = position
        let hasLeadingZero = position < bytes.count && bytes[position] == 0x30
        var value = 0
        var digits = 0
        while position < bytes.count, let digit = Self.digit(bytes[position], radix: radix) {
            position += 1
            value = value * radix + digit
            digits += 1
            if digits > maxDigits {
                position = start
                return nil
            }
        }
        if digits == 0 || (!allowsZeroPrefix && hasLeadingZero && digits > 1) {
            position = start
            return nil
        }
        return value
    }

    private mutating func read(_ byte: UInt8) -> Bool {
        guard position < bytes.count, bytes[position] == byte else { return false }
        position += 1
        return true
    }

    private static func digit(_ byte: UInt8, radix: Int) -> Int? {
        switch byte {
        case 0x30...0x39: return Int(byte - 0x30)
        case 0x61...0x66 where radix == 16: return Int(byte - 0x61 + 10)
        case 0x41...0x46 where radix == 16: return Int(byte - 0x41 + 10)
        default: return nil
        }
    }
}
