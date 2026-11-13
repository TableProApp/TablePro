//
//  SecretScanner.swift
//  TablePro
//

import Foundation

internal enum SecretKind: String, CaseIterable, Equatable, Sendable {
    case awsAccessKey
    case privateKey
    case jsonWebToken
    case gitHubToken
    case slackToken
    case stripeSecretKey
    case googleAPIKey
    case urlCredentials
    case passwordLiteral

    var displayName: String {
        switch self {
        case .awsAccessKey: String(localized: "AWS access key")
        case .privateKey: String(localized: "private key")
        case .jsonWebToken: String(localized: "JSON Web Token")
        case .gitHubToken: String(localized: "GitHub token")
        case .slackToken: String(localized: "Slack token")
        case .stripeSecretKey: String(localized: "Stripe secret key")
        case .googleAPIKey: String(localized: "Google API key")
        case .urlCredentials: String(localized: "URL with a password")
        case .passwordLiteral: String(localized: "password value")
        }
    }
}

internal struct SecretHit: Equatable, Sendable {
    let kind: SecretKind
    // 1-based.
    let line: Int
}

// Warns before a share goes public and never blocks one. The patterns are the core's (secret_scan.rs), in the regex
// features both engines share; `\p{White_Space}` is what Rust means by `\s`.
internal enum SecretScanner {
    private enum Starts {
        case anywhere
        // A word that runs into `://`.
        case wordBeforeScheme
        // A word holding a password-like name.
        case wordWithKeyword
    }

    private static let keywords = "(?:password|passwd|pwd|secret|token|api_key)"

    private static let patterns: [(SecretKind, String, Starts)] = [
        (.awsAccessKey, "AKIA[0-9A-Z]{16}", .anywhere),
        (.privateKey, "-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----", .anywhere),
        (.jsonWebToken, "eyJ[A-Za-z0-9_-]+\\.eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+", .anywhere),
        (.gitHubToken, "gh[pousr]_[A-Za-z0-9]{36,}", .anywhere),
        (.slackToken, "xox[abprs]-", .anywhere),
        (.stripeSecretKey, "sk_live_", .anywhere),
        (.googleAPIKey, "AIza[0-9A-Za-z_-]{35}", .anywhere),
        (.urlCredentials, "\\w+://[^\\p{White_Space}:/@]+:[^\\p{White_Space}@]+@", .wordBeforeScheme),
        // A name may close its own quote or bracket, as in JSON or T-SQL; the value closes with the quote it opened with.
        (
            .passwordLiteral,
            "(?i)\\w*\(keywords)\\w*[\"'`\\]]?\\p{White_Space}*(?:=>|:=|=|:)\\p{White_Space}*(?:'[^']+'|\"[^\"]+\")",
            .wordWithKeyword
        ),
    ]

    private static let compiled: [(SecretKind, NSRegularExpression, Starts)] = patterns.compactMap { kind, pattern, starts in
        (try? NSRegularExpression(pattern: pattern)).map { (kind, $0, starts) }
    }

    private static let wordRun = try? NSRegularExpression(pattern: "\\w+")
    private static let keyword = try? NSRegularExpression(pattern: "(?i)" + keywords)

    private static let sensitiveColumnTerms = [
        "password", "passwd", "secret", "token", "apikey", "ssn", "creditcard", "cardnumber"
    ]

    static func scanSQL(_ sql: String) -> [SecretHit] {
        let text = sql as NSString
        let starts = lineStarts(in: text)
        let words = wordRuns(in: text)
        var hits: [SecretHit] = []
        for (kind, expression, rule) in compiled {
            let lines = Set(matchLocations(expression, in: text, starts: rule, words: words).map {
                lineNumber(of: $0, starts: starts)
            })
            hits += lines.map { SecretHit(kind: kind, line: $0) }
        }
        return hits.sorted { ($0.line, $0.kind.sortOrder) < ($1.line, $1.kind.sortOrder) }
    }

    // ICU backtracks where Rust's automaton does not, so a long word would cost a pass per character. Only the places
    // a match can begin are tried, which finds the same matches: a leading `\w*` or `\w+` reaches back to its word's
    // start, and a word never runs across the end of an earlier match.
    private static func matchLocations(
        _ expression: NSRegularExpression,
        in text: NSString,
        starts rule: Starts,
        words: [NSRange]
    ) -> [Int] {
        let length = text.length
        let candidates: [Int]
        switch rule {
        case .anywhere:
            return expression.matches(in: text as String, range: NSRange(location: 0, length: length)).map(\.range.location)
        case .wordBeforeScheme:
            candidates = words.compactMap { run in
                let end = NSMaxRange(run)
                guard end + 3 <= length, text.character(at: end) == 0x3A, text.character(at: end + 1) == 0x2F,
                      text.character(at: end + 2) == 0x2F
                else { return nil }
                return run.location
            }
        case .wordWithKeyword:
            guard let keyword else { return [] }
            var starts: Set<Int> = []
            for found in keyword.matches(in: text as String, range: NSRange(location: 0, length: length)) {
                if let word = word(containing: found.range.location, in: words) {
                    starts.insert(word.location)
                }
            }
            candidates = starts.sorted()
        }
        var locations: [Int] = []
        var searchFrom = 0
        for candidate in candidates where candidate >= searchFrom {
            let range = NSRange(location: candidate, length: length - candidate)
            guard let match = expression.firstMatch(in: text as String, options: .anchored, range: range) else { continue }
            locations.append(match.range.location)
            searchFrom = max(NSMaxRange(match.range), candidate + 1)
        }
        return locations
    }

    private static func word(containing location: Int, in words: [NSRange]) -> NSRange? {
        var low = 0
        var high = words.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(words[middle]) <= location { low = middle + 1 } else { high = middle }
        }
        guard low < words.count, NSLocationInRange(location, words[low]) else { return nil }
        return words[low]
    }

    private static func wordRuns(in text: NSString) -> [NSRange] {
        guard let wordRun else { return [] }
        return wordRun.matches(in: text as String, range: NSRange(location: 0, length: text.length)).map(\.range)
    }

    static func scanColumns(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.filter { name in
            guard isSensitiveColumn(name), !seen.contains(name) else { return false }
            seen.insert(name)
            return true
        }
    }

    // Whole words as the share sheet's detectors split a name, so api_key, apiKey and API-KEY read alike and
    // class_name holds no "ssn".
    static func isSensitiveColumn(_ name: String) -> Bool {
        SensitiveDataDetector.longestTerm(in: SensitiveDataDetector.words(in: name), terms: sensitiveColumnTerms) != nil
    }

    // UTF-16 offsets where each line starts; a CRLF pair is one break.
    private static func lineStarts(in text: NSString) -> [Int] {
        var starts = [0]
        var index = 0
        while index < text.length {
            let unit = text.character(at: index)
            if unit == 0x0D, index + 1 < text.length, text.character(at: index + 1) == 0x0A {
                index += 2
                starts.append(index)
            } else {
                index += 1
                if unit == 0x0A || unit == 0x0D { starts.append(index) }
            }
        }
        return starts
    }

    private static func lineNumber(of location: Int, starts: [Int]) -> Int {
        var low = 0
        var high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= location { low = middle + 1 } else { high = middle }
        }
        return low
    }
}

private extension SecretKind {
    var sortOrder: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }
}
