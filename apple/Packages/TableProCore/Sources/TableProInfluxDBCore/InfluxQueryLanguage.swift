import Foundation

public enum InfluxQueryLanguage: String, Sendable, Equatable, Hashable, CaseIterable {
    case sql
    case influxQL = "influxql"
    case flux

    public var displayName: String {
        switch self {
        case .sql: return "SQL"
        case .influxQL: return "InfluxQL"
        case .flux: return "Flux"
        }
    }
}

public struct InfluxStatement: Sendable, Equatable {
    public let language: InfluxQueryLanguage
    public let text: String

    public init(language: InfluxQueryLanguage, text: String) {
        self.language = language
        self.text = text
    }

    // The marker is a TablePro directive, so it is blanked rather than removed: server error positions keep their line.
    public static func route(_ statement: String, generation: InfluxGeneration) throws -> InfluxStatement {
        let parsed = InfluxMarkedText(statement)
        let language = parsed.marker ?? guess(parsed.body, generation: generation)
        guard generation.languages.contains(language) else {
            throw InfluxError.unsupportedLanguage(language, generation: generation)
        }
        // `/query` runs every statement in the text, so a split the gate read differently would run unchecked.
        if language == .influxQL, !InfluxQLText.isSingleStatement(parsed.body) {
            throw InfluxError.multipleStatements
        }
        return InfluxStatement(language: language, text: parsed.body)
    }

    public static func marked(_ statement: String, language: InfluxQueryLanguage) -> String {
        "-- \(language.rawValue)\n" + statement
    }

    public static func isFlux(_ statement: String) -> Bool {
        let parsed = InfluxMarkedText(statement)
        if let marker = parsed.marker { return marker == .flux }
        return looksLikeFlux(parsed.body)
    }

    public static func fluxBody(of statement: String) -> String {
        InfluxMarkedText(statement).body
    }

    static func guess(_ text: String, generation: InfluxGeneration) -> InfluxQueryLanguage {
        if looksLikeFlux(text) { return .flux }
        switch generation {
        case .v2: return .influxQL
        case .v3: return looksLikeInfluxQLOnly(text) ? .influxQL : .sql
        }
    }

    static func looksLikeFlux(_ text: String) -> Bool {
        let code = InfluxNeutralCode.code(of: text)
        if code.contains("|>") { return true }
        return code.range(of: #"^(?:(?:from|buckets)\s*\(|(?:import|option)\s)"#, options: .regularExpression) != nil
    }

    private static let influxQLOnlyPrefixes = [
        "SHOW MEASUREMENT", "SHOW TAG", "SHOW FIELD", "SHOW SERIES", "SHOW RETENTION", "SHOW DATABASES",
    ]

    // DataFusion SQL rejects these; InfluxQL reads them.
    static func looksLikeInfluxQLOnly(_ text: String) -> Bool {
        let normalized = InfluxNeutralCode.code(of: text).uppercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        if influxQLOnlyPrefixes.contains(where: normalized.hasPrefix) { return true }
        if normalized.range(of: #"GROUP BY .*\bTIME\s*\("#, options: .regularExpression) != nil { return true }
        return normalized.range(of: #"NOW\(\)\s*[-+]\s*\d+(NS|U|µ|MS|S|M|H|D|W)\b"#, options: .regularExpression) != nil
    }
}

struct InfluxMarkedText {
    let marker: InfluxQueryLanguage?
    let body: String

    init(_ statement: String) {
        var lines = statement.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              let language = Self.marker(in: lines[index])
        else {
            marker = nil
            body = statement
            return
        }
        lines[index] = ""
        marker = language
        body = lines.joined(separator: "\n")
    }

    private static func marker(in line: String) -> InfluxQueryLanguage? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("--") || trimmed.hasPrefix("//") else { return nil }
        let word = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces).lowercased()
        return InfluxQueryLanguage(rawValue: word)
    }
}

// Comments dropped and quoted text and regex literals blanked, so a `|>` or `SHOW` inside any of them routes nothing.
// A comment or a regex goes before quotes count, since `// user's range` or `/'/` would otherwise open one.
enum InfluxNeutralCode {
    static func code(of text: String) -> String {
        let characters = Array(text)
        var output = ""
        var index = 0
        var lastCode: Character?
        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if character == "-" || character == "/", next == character {
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            }
            let opensRegex = character == "/" && (lastCode.map { "=~(,:[{>".contains($0) } ?? true)
            guard character == "'" || character == "\"" || opensRegex else {
                output.append(character)
                if !character.isWhitespace { lastCode = character }
                index += 1
                continue
            }
            output.append(character)
            index += 1
            while index < characters.count, characters[index] != character, !(opensRegex && characters[index] == "\n") {
                index += characters[index] == "\\" ? 2 : 1
            }
            if index < characters.count, characters[index] == character {
                output.append(character)
                index += 1
            }
            lastCode = character
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// InfluxQL's own scanner, enough to count statements: `--` and `/* */` comments, quotes with backslash pairs, and
// regex literals, in which `\/` is always an escaped slash. After `=~`, `!~`, `FROM`, `,` or `.` the parser reads a
// regex before it would see a `/*` comment, so there both readings must find one statement.
enum InfluxQLText {
    static func isSingleStatement(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        return [true, false].allSatisfy { statementCount(scalars, regexBeforeComment: $0) <= 1 }
    }

    private static let regexContexts: Set<String> = ["=~", "!~", "FROM", ",", "."]

    static func statementCount(_ scalars: [Unicode.Scalar], regexBeforeComment: Bool) -> Int {
        var index = 0
        var count = 0
        var hasCode = false
        var operandEnded = false
        var last = ""

        func peek(_ offset: Int = 0) -> Unicode.Scalar? {
            index + offset < scalars.count ? scalars[index + offset] : nil
        }

        func skipRegex() {
            index += 1
            while let next = peek(), next != "/", next != "\n" {
                index += next == "\\" && peek(1) == "/" ? 2 : 1
            }
            index += 1
        }

        while let scalar = peek() {
            let opensComment = scalar == "/" && peek(1) == "*"
            if scalar.properties.isWhitespace {
                index += 1
            } else if scalar == "-", peek(1) == "-" {
                while let next = peek(), next != "\n" { index += 1 }
            } else if opensComment, !(regexBeforeComment && regexContexts.contains(last)) {
                index += 2
                while peek() != nil, !(peek() == "*" && peek(1) == "/") { index += 1 }
                index += 2
            } else if scalar == ";" {
                if hasCode { count += 1 }
                hasCode = false
                operandEnded = false
                last = ""
                index += 1
            } else {
                hasCode = true
                if scalar == "\'" || scalar == "\"" {
                    index += 1
                    while let next = peek(), next != scalar {
                        index += next == "\\" ? 2 : 1
                    }
                    index += 1
                    operandEnded = true
                    last = "quoted"
                } else if scalar == "/", !operandEnded {
                    skipRegex()
                    operandEnded = true
                    last = "regex"
                } else if scalar == "_" || scalar.properties.isAlphabetic || ("0" ... "9").contains(scalar) {
                    var word = String.UnicodeScalarView()
                    while let next = peek(), next == "_" || next.properties.isAlphabetic || ("0" ... "9").contains(next) {
                        word.append(next)
                        index += 1
                    }
                    last = String(word).uppercased()
                    operandEnded = last != "FROM"
                } else {
                    let symbol = String(Character(scalar))
                    last = scalar == "~" && (last == "=" || last == "!") ? last + symbol : symbol
                    operandEnded = scalar == ")" || scalar == "]"
                    index += 1
                }
            }
        }
        return hasCode ? count + 1 : count
    }
}
