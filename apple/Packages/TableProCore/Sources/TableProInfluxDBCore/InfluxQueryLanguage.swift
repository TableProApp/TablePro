import Foundation

public enum InfluxQueryLanguage: String, Sendable, Equatable, CaseIterable {
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

/// Picks the language a statement is sent in. The server version decides which languages exist;
/// within them the statement's own text decides, so the grid's `SELECT` and a typed Flux pipeline
/// both run without a setting to flip. A first-line comment naming a language (`-- influxql`,
/// `// flux`) overrides the guess.
public enum InfluxLanguageRouter {
    public static func language(
        for statement: String,
        generation: InfluxGeneration
    ) throws -> InfluxQueryLanguage {
        let language = hint(in: statement) ?? guess(statement, generation: generation)
        guard generation.languages.contains(language) else {
            throw InfluxError.unsupportedLanguage(language, generation: generation)
        }
        return language
    }

    static func hint(in statement: String) -> InfluxQueryLanguage? {
        let firstLine = statement
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? ""
        let body: Substring
        if firstLine.hasPrefix("--") {
            body = firstLine.dropFirst(2)
        } else if firstLine.hasPrefix("//") {
            body = firstLine.dropFirst(2)
        } else {
            return nil
        }
        return InfluxQueryLanguage(rawValue: body.trimmingCharacters(in: .whitespaces).lowercased())
    }

    static func guess(_ statement: String, generation: InfluxGeneration) -> InfluxQueryLanguage {
        let code = strippingLeadingComments(statement)
        if looksLikeFlux(code) {
            return .flux
        }
        switch generation {
        case .v1, .v2:
            return .influxQL
        case .v3:
            return looksLikeInfluxQLOnly(code) ? .influxQL : .sql
        }
    }

    static func looksLikeFlux(_ code: String) -> Bool {
        if code.contains("|>") { return true }
        let lowered = code.lowercased()
        return ["from(", "import ", "buckets(", "option "].contains { lowered.hasPrefix($0) }
    }

    private static let influxQLOnlyPrefixes = [
        "SHOW MEASUREMENT", "SHOW TAG", "SHOW FIELD", "SHOW SERIES", "SHOW RETENTION", "SHOW DATABASES",
    ]

    /// Statements DataFusion SQL rejects but InfluxQL reads: its `SHOW` catalog commands,
    /// `GROUP BY time(...)` buckets and duration literals such as `now() - 1h`.
    static func looksLikeInfluxQLOnly(_ code: String) -> Bool {
        let normalized = code.uppercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if influxQLOnlyPrefixes.contains(where: normalized.hasPrefix) { return true }
        if normalized.range(of: #"GROUP BY .*\bTIME\s*\("#, options: .regularExpression) != nil { return true }
        return normalized.range(of: #"NOW\(\)\s*[-+]\s*\d+(NS|U|µ|MS|S|M|H|D|W)\b"#, options: .regularExpression) != nil
    }

    static func strippingLeadingComments(_ statement: String) -> String {
        var lines = statement.components(separatedBy: .newlines)[...]
        while let first = lines.first {
            let trimmed = first.trimmingCharacters(in: .whitespaces)
            guard trimmed.isEmpty || trimmed.hasPrefix("--") || trimmed.hasPrefix("//") else { break }
            lines = lines.dropFirst()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
