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

// Warns before a share goes public and never blocks one; every TablePro app scans for these patterns.
internal enum SecretScanner {
    // Possessive runs and a start-of-run lookbehind keep each pattern linear on a long token.
    private static let patterns: [(SecretKind, String)] = [
        (.awsAccessKey, "AKIA[0-9A-Z]{16}"),
        (.privateKey, "-----BEGIN [A-Z ]*PRIVATE KEY-----"),
        (.jsonWebToken, "eyJ[\\w-]++\\.eyJ[\\w-]++\\.[\\w-]++"),
        (.gitHubToken, "gh[pousr]_[A-Za-z0-9]{36,}"),
        (.slackToken, "xox[abprs]-"),
        (.stripeSecretKey, "sk_live_"),
        (.googleAPIKey, "AIza[0-9A-Za-z_-]{35}"),
        (.urlCredentials, "(?<!\\w)\\w++://[^\\s:/@]++:[^\\s@]++@"),
        (
            .passwordLiteral,
            "(?i)(?<!\\w)\\w*?(?:password|passwd|pwd|secret|token|api_key)\\w*+[\"`\\]]?\\s*+(?::=|=>|=|:)\\s*+(?:'[^'\\n]++'|\"[^\"\\n]++\")"
        ),
    ]

    private static let compiled: [(SecretKind, NSRegularExpression)] = patterns.compactMap { kind, pattern in
        (try? NSRegularExpression(pattern: pattern)).map { (kind, $0) }
    }

    private static let sensitiveColumnWords = [
        "password", "passwd", "secret", "token", "apikey", "creditcard", "cardnumber"
    ]

    static func scanSQL(_ sql: String) -> [SecretHit] {
        let text = sql as NSString
        let whole = NSRange(location: 0, length: text.length)
        let starts = lineStarts(in: text)
        var hits: [SecretHit] = []
        for (kind, expression) in compiled {
            var lines: Set<Int> = []
            for match in expression.matches(in: sql, range: whole) {
                lines.insert(lineNumber(of: match.range.location, starts: starts))
            }
            hits += lines.map { SecretHit(kind: kind, line: $0) }
        }
        return hits.sorted { ($0.line, $0.kind.sortOrder) < ($1.line, $1.kind.sortOrder) }
    }

    static func scanColumns(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.filter { name in
            guard isSensitiveColumn(name), !seen.contains(name) else { return false }
            seen.insert(name)
            return true
        }
    }

    static func isSensitiveColumn(_ name: String) -> Bool {
        let lowered = name.lowercased()
        let compact = String(lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        if sensitiveColumnWords.contains(where: { compact.contains($0) }) {
            return true
        }
        return words(in: name).contains("ssn")
    }

    private static func words(in name: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previousWasLower = false
        for character in name {
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { words.append(current.lowercased()) }
                current = ""
                previousWasLower = false
                continue
            }
            if character.isUppercase, previousWasLower, !current.isEmpty {
                words.append(current.lowercased())
                current = ""
            }
            current.append(character)
            previousWasLower = character.isLowercase
        }
        if !current.isEmpty { words.append(current.lowercased()) }
        return words
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
